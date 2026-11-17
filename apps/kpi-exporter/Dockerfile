FROM python:3.15-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Tests run during the build against real gNB messages (testdata/): a failing
# test fails the image build, in CI on every PR. They are removed afterwards.
COPY app.py test_app.py ./
COPY testdata/ testdata/
RUN python -m unittest -v test_app && rm -rf test_app.py testdata __pycache__

RUN useradd --uid 10001 --no-create-home exporter
USER 10001

EXPOSE 9100
CMD ["python", "-u", "app.py"]
