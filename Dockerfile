FROM python:3.12-slim
WORKDIR /app
RUN pip install django gunicorn
COPY . .
ENV DJANGO_ALLOWED_HOSTS="*"
EXPOSE 8000
CMD ["gunicorn", "core.wsgi:application", "--bind", "0.0.0.0:8000"]
