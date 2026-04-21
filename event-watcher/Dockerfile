FROM python:3.11-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py .
RUN mkdir -p /data
EXPOSE 8002
HEALTHCHECK --interval=15s --timeout=5s CMD curl -f http://localhost:8002/health || exit 1
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8002"]
