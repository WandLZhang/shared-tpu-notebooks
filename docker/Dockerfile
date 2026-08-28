FROM quay.io/jupyter/scipy-notebook:2024-11-11

USER root

# Install dependencies needed for JAX/TPU and Kubernetes operations
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

USER ${NB_UID}

COPY requirements.txt /tmp/requirements.txt

# Install python requirements
RUN pip install --no-cache-dir -r /tmp/requirements.txt
