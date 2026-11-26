FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 ROOT=/data CONFIG_DIR=/config PORT=9191
WORKDIR /app
RUN pip install --no-cache-dir flask waitress curl_cffi
COPY app/ /app/
EXPOSE 9191
CMD ["python", "app.py"]
