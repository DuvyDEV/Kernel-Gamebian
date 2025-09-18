FROM python:3.13-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      dpkg-dev apt-utils apt-transport-https gnupg dirmngr ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Librerías Python
RUN pip install --no-cache-dir requests

# Rutas fijas
ENV REPO_DIR=/var/www/debian-redroot
ENV GNUPGHOME=/gnupg
RUN mkdir -p ${REPO_DIR} ${GNUPGHOME} && chmod 700 ${GNUPGHOME}

# App
WORKDIR /app
COPY update_repo.py server.py run.py init_gpg.py /app/
RUN chmod +x /app/*.py

EXPOSE 8000

# Inicializa GPG (si no existe en el volumen) y arranca servidor+updater
CMD ["bash","-lc","/app/init_gpg.py && /app/run.py"]

