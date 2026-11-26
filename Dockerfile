FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 ROOT=/data CONFIG_DIR=/config PORT=9191 ENABLE_BROWSER=1
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY app/ /app/
EXPOSE 9191
CMD ["python", "app.py"]
