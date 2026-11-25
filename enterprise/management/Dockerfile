FROM python:3.12.12-slim
WORKDIR /srv/management
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py settings.py migrate.py provision.py local_auth.py ad_sync.py enrollment_broker.py corporate_grants.py *.sql ./
ENV PYTHONDONTWRITEBYTECODE=1
USER 65532:65532
EXPOSE 8080
CMD ["uvicorn", "app:production_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-proxy-headers", "--no-access-log"]
