# syntax=docker/dockerfile:1.7
FROM public.ecr.aws/docker/library/python:3.13-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --target /deps -r requirements.txt

FROM public.ecr.aws/docker/library/python:3.13-slim

COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.0.1 /lambda-adapter /opt/extensions/lambda-adapter

COPY --from=build /deps /var/task
COPY app /var/task/app

ENV PYTHONPATH=/var/task \
    AWS_LWA_PORT=8080 \
    AWS_LWA_READINESS_CHECK_PATH=/health \
    AWS_LWA_READINESS_CHECK_PROTOCOL=http \
    AWS_LWA_ASYNC_INIT=true

WORKDIR /var/task
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
