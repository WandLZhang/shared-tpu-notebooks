FROM quay.io/jupyter/scipy-notebook:2024-11-11

# Switch to root to install system-wide or modify base layers if needed,
# though pip install can run as jovyan for user-level packages.
USER root

# Pre-install the kubernetes client so submit_tpu.py has it immediately on spawn,
# saving 5-10 seconds of cold start time compared to a postStart hook.
RUN pip install --no-cache-dir kubernetes

# Switch back to the default unprivileged user
USER jovyan
