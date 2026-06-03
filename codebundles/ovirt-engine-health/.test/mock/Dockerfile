FROM python:3.12-slim
WORKDIR /app
COPY ovirt_mock.py .
ENV MOCK_SCENARIO=unhealthy
ENV MOCK_PORT=8080
EXPOSE 8080
CMD ["python3", "ovirt_mock.py"]
