FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY proxy.py .

EXPOSE 4000

CMD ["uvicorn", "proxy:app", "--host", "0.0.0.0", "--port", "4000", "--log-level", "warning"]
