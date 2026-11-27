use hbb_common::{
    base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine},
    sodiumoxide::crypto::{auth::hmacsha256, sign},
};
use serde::{Deserialize, Serialize};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
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

impl Transport {
    fn connection_id(&self) -> Uuid {
        let mut bytes = [0; 16];
        bytes.copy_from_slice(&self.binding.as_ref()[..16]);
        Uuid::from_bytes(bytes)
    }
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

#[derive(Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Mode {
    Consent,
    Unattended,
}

impl Mode {
    fn as_str(self) -> &'static str {
        match self {
            Self::Consent => "consent",
            Self::Unattended => "unattended",
        }
    }
}

fn valid_operator(operator: &str) -> bool {
    (3..=64).contains(&operator.len())
        && operator
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
}

fn epoch() -> Result<u64, CorporateDenial> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|now| now.as_secs())
        .map_err(|_| CorporateDenial::EndpointVerificationUnavailable)
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
) -> Result<Claims, CorporateDenial> {
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
        || !valid_operator(&claims.sub)
        || claims.iat > now
        || claims.exp <= now
        || claims.exp.saturating_sub(claims.iat) > MAX_LIFETIME
    {
        return Err(InvalidGrant);
    }
    if claims.device != trust.device.to_string()
        || claims.endpoint != hex::encode(trust.certificate)
        || claims.endpoint_key != hex::encode(transport.endpoint_key)
        || claims.connection != transport.connection_id().to_string()
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
    Ok(claims)
}

#[cfg(windows)]
fn load_endpoint() -> Result<(Trust, reqwest::Url), CorporateDenial> {
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
    let url: String = key.get_value("ManagementUrl").map_err(|_| unavailable)?;
    let url = reqwest::Url::parse(&url).map_err(|_| unavailable)?;
    if url.scheme() != "https"
        || url.host().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(unavailable);
    }
    Ok((trust, url))
}

#[cfg(not(windows))]
fn load_endpoint() -> Result<(Trust, reqwest::Url), CorporateDenial> {
    Err(CorporateDenial::EndpointVerificationUnavailable)
}

#[derive(Serialize)]
struct Proof<'a> {
    operator: &'a str,
    mode: &'static str,
    connection_id: String,
    handshake: String,
    timestamp: u64,
    signature: String,
}

fn sign_proof<'a>(
    transport: &Transport,
    device: Uuid,
    operator: &'a str,
    mode: Mode,
    grant: Option<&str>,
) -> Result<Proof<'a>, CorporateDenial> {
    use hbb_common::{config::Config, sodiumoxide::crypto::hash::sha256};
    let unavailable = CorporateDenial::EndpointVerificationUnavailable;
    let (secret, _) = Config::get_key_pair();
    let secret = sign::SecretKey::from_slice(&secret).ok_or(unavailable)?;
    if secret.public_key().0 != transport.endpoint_key {
        return Err(unavailable);
    }
    let mut proof = Proof {
        operator,
        mode: mode.as_str(),
        connection_id: transport.connection_id().to_string(),
        handshake: hex::encode(transport.binding.as_ref()),
        timestamp: epoch()?,
        signature: String::new(),
    };
    let digest = grant
        .map(|token| hex::encode(sha256::hash(token.as_bytes()).as_ref()))
        .unwrap_or_default();
    let purpose = if grant.is_some() { "redeem" } else { "issue" };
    let payload = format!(
        "YES Desk endpoint proof v1\n{purpose}\n{device}\n{}\n{}\n{}\n{}\n{}\n{digest}",
        proof.operator, proof.mode, proof.connection_id, proof.handshake, proof.timestamp
    );
    proof.signature = hex::encode(sign::sign_detached(payload.as_bytes(), &secret).to_bytes());
    Ok(proof)
}

pub(super) struct Attempt {
    operator: String,
    mode: Mode,
    deadline: std::time::Instant,
}

pub(super) struct Admission {
    pub(super) operator: String,
    pub(super) grant_id: String,
}

pub(super) fn challenge(
    request: &hbb_common::message_proto::CorporateChallengeRequest,
    transport: &Transport,
) -> Result<(Attempt, hbb_common::message_proto::CorporateChallenge), CorporateDenial> {
    use CorporateDenial::*;
    let mode = match request.mode.as_str() {
        "consent" => Mode::Consent,
        "unattended" => Mode::Unattended,
        _ => return Err(InvalidGrant),
    };
    if !valid_operator(&request.operator) {
        return Err(InvalidGrant);
    }
    let (trust, _) = load_endpoint()?;
    if !match mode {
        Mode::Consent => trust.consent,
        Mode::Unattended => trust.unattended,
    } {
        return Err(LocalPolicyDenied);
    }
    let proof = sign_proof(transport, trust.device, &request.operator, mode, None)?;
    let message = hbb_common::message_proto::CorporateChallenge {
        device_id: trust.device.to_string(),
        endpoint_key: transport.endpoint_key.to_vec().into(),
        issue_proof: serde_json::to_string(&proof).map_err(|_| InvalidGrant)?,
        ..Default::default()
    };
    Ok((
        Attempt {
            operator: request.operator.clone(),
            mode,
            deadline: std::time::Instant::now() + Duration::from_secs(MAX_LIFETIME),
        },
        message,
    ))
}

fn redemption_client() -> reqwest::ClientBuilder {
    reqwest::Client::builder()
        .use_native_tls()
        .https_only(true)
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(5))
}

async fn redeem_json(
    client: &reqwest::Client,
    url: reqwest::Url,
    body: &impl Serialize,
) -> Result<(), CorporateDenial> {
    let response = client
        .post(url)
        .json(body)
        .send()
        .await
        .map_err(|_| CorporateDenial::EndpointRedemptionUnavailable)?;
    match response.status().as_u16() {
        204 => Ok(()),
        403 | 409 => Err(CorporateDenial::EndpointRedemptionDenied),
        _ => Err(CorporateDenial::EndpointRedemptionUnavailable),
    }
}

pub(super) async fn redeem(
    grant: &str,
    transport: &Transport,
    attempt: Attempt,
) -> Result<Admission, CorporateDenial> {
    use CorporateDenial::*;
    let (trust, _) = load_endpoint()?;
    let claims = check_grant(grant, transport, &trust, epoch()?)?;
    if claims.sub != attempt.operator
        || claims.mode != attempt.mode
        || std::time::Instant::now() >= attempt.deadline
    {
        return Err(GrantContextMismatch);
    }
    #[cfg(windows)]
    let console = if claims.mode == Mode::Consent {
        let remaining = claims
            .exp
            .saturating_sub(epoch()?)
            .saturating_sub(1)
            .min(12);
        if remaining == 0 {
            return Err(LocalConsentUnavailable);
        }
        let operator = claims.sub.clone();
        let answer = hbb_common::tokio::task::spawn_blocking(move || {
            crate::platform::request_corporate_console_consent(&operator, remaining as u32)
        })
        .await
        .map_err(|_| LocalConsentUnavailable)?;
        answer.ok_or(LocalConsentUnavailable)?
    } else {
        crate::platform::CorporateConsoleConsent::current().ok_or(LocalPolicyDenied)?
    };
    #[cfg(not(windows))]
    if claims.mode == Mode::Consent {
        return Err(LocalConsentUnavailable);
    }
    let (trust, mut api) = load_endpoint()?;
    check_grant(grant, transport, &trust, epoch()?)?;
    #[cfg(windows)]
    if !console.still_current() {
        return Err(LocalConsentUnavailable);
    }
    api.path_segments_mut()
        .map_err(|_| EndpointRedemptionUnavailable)?
        .pop_if_empty()
        .extend([
            "v2",
            "devices",
            claims.device.as_str(),
            "session-grants",
            "redeem",
        ]);
    #[derive(Serialize)]
    struct Redemption<'a> {
        #[serde(flatten)]
        proof: Proof<'a>,
        grant: &'a str,
    }
    let proof = sign_proof(
        transport,
        trust.device,
        &claims.sub,
        claims.mode,
        Some(grant),
    )?;
    let client = redemption_client()
        .build()
        .map_err(|_| EndpointRedemptionUnavailable)?;
    redeem_json(&client, api, &Redemption { proof, grant }).await?;
    let (trust, _) = load_endpoint()?;
    check_grant(grant, transport, &trust, epoch()?)?;
    #[cfg(windows)]
    if !console.still_current() {
        return Err(LocalConsentUnavailable);
    }
    if std::time::Instant::now() >= attempt.deadline {
        return Err(InvalidGrant);
    }
    Ok(Admission { operator: claims.sub, grant_id: claims.jti })
}

#[cfg(test)]
mod tests {
    use super::*;
    use hbb_common::tokio;
    use serde_json::json;

    #[hbb_common::tokio::test]
    #[ignore = "run with enterprise/management/test_redemption_https.py"]
    async fn redemption_uses_verified_https_and_requires_204() {
        use CorporateDenial::*;
        let base = std::env::var("YESDESK_TEST_REDEMPTION_URL").unwrap();
        let ca = std::fs::read(std::env::var_os("YESDESK_TEST_REDEMPTION_CA").unwrap()).unwrap();
        let body = json!({"grant": "test-http-transport"});
        let trusted = redemption_client()
            .add_root_certificate(reqwest::Certificate::from_pem(&ca).unwrap())
            .build()
            .unwrap();
        let untrusted = redemption_client().build().unwrap();

        for (path, outcome) in [
            ("204", Ok(())),
            ("403", Err(EndpointRedemptionDenied)),
            ("409", Err(EndpointRedemptionDenied)),
            ("503", Err(EndpointRedemptionUnavailable)),
            ("302", Err(EndpointRedemptionUnavailable)),
            ("timeout", Err(EndpointRedemptionUnavailable)),
        ] {
            let url = reqwest::Url::parse(&format!("{base}/{path}")).unwrap();
            assert_eq!(redeem_json(&trusted, url, &body).await, outcome, "{path}");
        }
        let url = reqwest::Url::parse(&format!("{base}/204")).unwrap();
        assert_eq!(
            redeem_json(&untrusted, url, &body).await,
            Err(EndpointRedemptionUnavailable)
        );
        let unavailable = std::env::var("YESDESK_TEST_REDEMPTION_UNAVAILABLE")
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(
            redeem_json(&trusted, unavailable, &body).await,
            Err(EndpointRedemptionUnavailable)
        );
    }

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
        assert_eq!(
            check_grant(&grant, &transport, &trust, 105).map(drop),
            Ok(())
        );
        assert_eq!(
            check_grant(&grant, &transport, &trust, 120).map(drop),
            Err(CorporateDenial::InvalidGrant)
        );
        let corrupted = format!(
            "{}.{}",
            grant.rsplit_once('.').unwrap().0,
            URL_SAFE_NO_PAD.encode([0; 64])
        );
        assert_eq!(
            check_grant(&corrupted, &transport, &trust, 105).map(drop),
            Err(CorporateDenial::InvalidGrant)
        );
        let wrong = Transport {
            binding: hmacsha256::Tag([6; 32]),
            ..transport
        };
        assert_eq!(
            check_grant(&grant, &wrong, &trust, 105).map(drop),
            Err(CorporateDenial::GrantContextMismatch)
        );
        claims["mode"] = json!("unattended");
        assert_eq!(
            check_grant(&sign_grant(&claims), &transport, &trust, 105).map(drop),
            Err(CorporateDenial::LocalPolicyDenied)
        );
        trust.unattended = true;
        assert_eq!(
            check_grant(&sign_grant(&claims), &transport, &trust, 105).map(drop),
            Ok(())
        );
    }
}
