FROM python:3.11-slim-bullseye

# Allow statements and log messages to immediately appear in the Knative logs
ENV PYTHONUNBUFFERED True
# Fixes "invalid instruction" runtime error on AMD machines (specifically HF Upgraded CPU Space).
ENV HNSWLIB_NO_NATIVE 1

# Adds GCC and other build tools so we can compile hnswlib and other native/C++ deps.
RUN apt-get update --fix-missing && apt-get install -y --fix-missing build-essential && \
  rm -rf /var/lib/apt/lists/*

# Set the working directory in the container.
WORKDIR /app

# To reduce the image size, replace lilac[all] with lilac[...] optional deps.
RUN python -m pip install lilac[all]

# Install from the local wheel inside ./dist. This will be a no-op if the wheel is not found.
COPY --chown=user /dis[t] ./dist/
RUN python -m pip install --find-links=dist --upgrade lilac[all]

COPY LICENSE .

# Google cloud does not support -p forwarding, so we pass port 80 as an argument in the config.
EXPOSE 80
CMD ["uvicorn", "lilac.server:app", "--host", "0.0.0.0", "--port", "80"]
