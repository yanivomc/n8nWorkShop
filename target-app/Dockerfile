FROM python:3.11-slim

WORKDIR /app

# Install deps first (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source — split so code changes don't bust dep cache
COPY config.py .
COPY main.py .
COPY routes/ routes/
COPY chaos/ chaos/

# Create empty __init__.py files
RUN touch routes/__init__.py chaos/__init__.py

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "info"]
