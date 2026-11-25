use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine},
    sodiumoxide::crypto::{auth::hmacsha256, sign},
};
use serde::Deserialize;
use uuid::Uuid;

use super::connection::CorporateDenial;

const ISSUER: &str = "yesdesk-management";
const AUDIENCE: &str = "yesdesk-corporate-endpoint";
const TOKEN_TYPE: &str = "yesdesk-session-grant+jwt";
const MAX_LIFETIME: u64 = 30;

pub(super) struct Transport {
    pub(super) binding: hmacsha256::Tag,
    pub(super) endpoint_key: [u8; 32],
}

struct Trust {
    device: Uuid,
    certificate: [u8; 32],
    management_key: sign::PublicKey,
    consent: bool,
    unattended: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Header {
    alg: String,
    typ: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Mode {
    Consent,
    Unattended,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Claims {
    iss: String,
    aud: String,
    sub: String,
    jti: String,
    device: String,
    endpoint: String,
    endpoint_key: String,
    mode: Mode,
    connection: String,
    handshake: String,
    iat: u64,
    exp: u64,
}

fn check_grant(
    grant: &str,
    transport: &Transport,
    trust: &Trust,
    now: u64,
) -> Result<(), CorporateDenial> {
    use CorporateDenial::*;
    if grant.len() > 2048 {
        return Err(InvalidGrant);
    }
    let (signed, signature) = grant.rsplit_once('.').ok_or(InvalidGrant)?;
    let signature = URL_SAFE_NO_PAD
        .decode(signature)
        .map_err(|_| InvalidGrant)?;
    let signature = sign::Signature::from_bytes(&signature).map_err(|_| InvalidGrant)?;
    if !sign::verify_detached(&signature, signed.as_bytes(), &trust.management_key) {
        return Err(InvalidGrant);
    }
    let (header, payload) = signed.split_once('.').ok_or(InvalidGrant)?;
    let header = URL_SAFE_NO_PAD.decode(header).map_err(|_| InvalidGrant)?;
    let header: Header = serde_json::from_slice(&header).map_err(|_| InvalidGrant)?;
    if header.alg != "EdDSA" || header.typ != TOKEN_TYPE {
        return Err(InvalidGrant);
    }
    let payload = URL_SAFE_NO_PAD.decode(payload).map_err(|_| InvalidGrant)?;
    let claims: Claims = serde_json::from_slice(&payload).map_err(|_| InvalidGrant)?;
    if claims.iss != ISSUER
        || claims.aud != AUDIENCE
        || !Uuid::parse_str(&claims.jti)
            .is_ok_and(|id| !id.is_nil() && id.to_string() == claims.jti)
        || !(3..=64).contains(&claims.sub.len())
        || !claims
            .sub
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
        || claims.iat > now
        || claims.exp <= now
        || claims.exp.saturating_sub(claims.iat) > MAX_LIFETIME
    {
        return Err(InvalidGrant);
    }
    let mut connection_bytes = [0; 16];
    connection_bytes.copy_from_slice(&transport.binding.as_ref()[..16]);
    if claims.device != trust.device.to_string()
        || claims.endpoint != hex::encode(trust.certificate)
        || claims.endpoint_key != hex::encode(transport.endpoint_key)
        || claims.connection != Uuid::from_bytes(connection_bytes).to_string()
        || claims.handshake != hex::encode(transport.binding.as_ref())
    {
        return Err(GrantContextMismatch);
    }
    if !match claims.mode {
        Mode::Consent => trust.consent,
        Mode::Unattended => trust.unattended,
    } {
        return Err(LocalPolicyDenied);
    }
    Ok(())
}

#[cfg(windows)]
pub(super) fn check_at_endpoint(grant: &str, transport: &Transport) -> Result<(), CorporateDenial> {
    use std::time::{SystemTime, UNIX_EPOCH};
    use winreg::{
        enums::{HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_64KEY},
        RegKey,
    };

    let unavailable = CorporateDenial::EndpointVerificationUnavailable;
    if !crate::is_server() || !crate::platform::is_root() {
        return Err(unavailable);
    }
    let key = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey_with_flags(
            r"SOFTWARE\YES Apart\YES Desk\CorporateSession",
            KEY_READ | KEY_WOW64_64KEY,
        )
        .map_err(|_| unavailable)?;
    let device: String = key.get_value("DeviceId").map_err(|_| unavailable)?;
    let certificate: String = key
        .get_value("CertificateFingerprint")
        .map_err(|_| unavailable)?;
    let management_key: String = key
        .get_value("ManagementSigningKey")
        .map_err(|_| unavailable)?;
    let mut fingerprint = [0; 32];
    let mut public_key = [0; 32];
    hex::decode_to_slice(certificate, &mut fingerprint).map_err(|_| unavailable)?;
    hex::decode_to_slice(management_key, &mut public_key).map_err(|_| unavailable)?;
    let trust = Trust {
        device: Uuid::parse_str(&device).map_err(|_| unavailable)?,
        certificate: fingerprint,
        management_key: sign::PublicKey(public_key),
        consent: key.get_value::<u32, _>("AllowConsent").unwrap_or(0) == 1,
        unattended: key.get_value::<u32, _>("AllowUnattended").unwrap_or(0) == 1,
    };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| unavailable)?
        .as_secs();
    check_grant(grant, transport, &trust, now)
}

#[cfg(not(windows))]
pub(super) fn check_at_endpoint(_: &str, _: &Transport) -> Result<(), CorporateDenial> {
    Err(CorporateDenial::EndpointVerificationUnavailable)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn signed_grant_requires_current_bound_context_and_local_policy() {
        hbb_common::sodiumoxide::init().unwrap();
        let (pk, sk) = sign::gen_keypair();
        let mut trust = Trust {
            device: Uuid::from_bytes([1; 16]),
            certificate: [2; 32],
            management_key: pk,
            consent: true,
            unattended: false,
        };
        let transport = Transport {
            binding: hmacsha256::Tag([3; 32]),
            endpoint_key: [4; 32],
        };
        let mut claims = json!({
            "iss": ISSUER, "aud": AUDIENCE, "sub": "lab-operator",
            "jti": Uuid::from_bytes([5; 16]).to_string(), "device": trust.device.to_string(),
            "endpoint": hex::encode(trust.certificate), "endpoint_key": hex::encode(transport.endpoint_key),
            "mode": "consent", "connection": Uuid::from_bytes([3; 16]).to_string(),
            "handshake": hex::encode(transport.binding.as_ref()), "iat": 100u64, "exp": 120u64,
        });
        let sign_grant = |claims: &serde_json::Value| {
            let header = json!({ "alg": "EdDSA", "typ": TOKEN_TYPE });
            let signed = format!(
                "{}.{}",
                URL_SAFE_NO_PAD.encode(header.to_string()),
                URL_SAFE_NO_PAD.encode(claims.to_string())
            );
            let signature = sign::sign_detached(signed.as_bytes(), &sk);
            format!(
                "{}.{}",
                signed,
                URL_SAFE_NO_PAD.encode(signature.to_bytes())
            )
        };
        let grant = sign_grant(&claims);
        assert_eq!(check_grant(&grant, &transport, &trust, 105), Ok(()));
        assert_eq!(
            check_grant(&grant, &transport, &trust, 120),
            Err(CorporateDenial::InvalidGrant)
        );
        let corrupted = format!(
            "{}.{}",
            grant.rsplit_once('.').unwrap().0,
            URL_SAFE_NO_PAD.encode([0; 64])
        );
        assert_eq!(
            check_grant(&corrupted, &transport, &trust, 105),
            Err(CorporateDenial::InvalidGrant)
        );
        let wrong = Transport {
            binding: hmacsha256::Tag([6; 32]),
            ..transport
        };
        assert_eq!(
            check_grant(&grant, &wrong, &trust, 105),
            Err(CorporateDenial::GrantContextMismatch)
        );
        claims["mode"] = json!("unattended");
        assert_eq!(
            check_grant(&sign_grant(&claims), &transport, &trust, 105),
            Err(CorporateDenial::LocalPolicyDenied)
        );
        trust.unattended = true;
        assert_eq!(
            check_grant(&sign_grant(&claims), &transport, &trust, 105),
            Ok(())
        );
    }
}
