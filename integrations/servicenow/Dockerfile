FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY webhook_receiver.py .

EXPOSE 8095

CMD ["python", "webhook_receiver.py"]
