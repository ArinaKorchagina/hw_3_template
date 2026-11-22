FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PORT=8000

WORKDIR /app

# Зависимости отдельным слоем: он пересобирается только при изменении requirements.txt
COPY app/requirements.txt .
RUN pip install -r requirements.txt

COPY app/app.py .

# Непривилегированный пользователь (UID 10001) и каталог данных для режима sqlite
RUN useradd --system --uid 10001 --user-group --no-create-home --shell /usr/sbin/nologin app \
    && mkdir /data \
    && chown app:app /data

USER 10001:10001

EXPOSE 8000

CMD ["python", "app.py"]
