# The image shape this example's function expects. It is here as consumer guidance rather than as
# something Terraform builds: CI builds and pushes the image, and Terraform only ever holds the
# seed URI.
#
# Two properties matter. The base is an ordinary Python image, not public.ecr.aws/lambda/python,
# because the Lambda Web Adapter ships the Runtime Interface Client itself and the point of the
# adapter is to run the application unchanged. And the build is multi-stage, so the compiler
# toolchain used to build wheels never reaches the runtime layer, which is the single biggest
# lever on both image size and cold start.

# syntax=docker/dockerfile:1.7
FROM public.ecr.aws/docker/library/python:3.13-slim AS build
WORKDIR /build
COPY requirements.txt .
RUN pip install --no-cache-dir --target /deps -r requirements.txt

FROM public.ecr.aws/docker/library/python:3.13-slim

# The adapter installs as a Lambda external extension. Pin the exact version: this is the piece
# that turns an invoke event into an HTTP request, and it is not a place for a floating tag.
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
