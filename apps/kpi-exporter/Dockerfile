FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN useradd --uid 10001 --no-create-home exporter
USER 10001

EXPOSE 9100
CMD ["python", "-u", "app.py"]
