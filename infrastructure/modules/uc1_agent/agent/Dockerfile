FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

# Non-root user for security hardening.
RUN adduser --disabled-password --gecos "" appuser

# Copy dependency manifest first for layer caching — avoids reinstall on
# app-code-only changes.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code after dependencies are installed.
COPY app/ ./app/

# Drop to non-root before execution.
USER appuser

EXPOSE 8080

# Run as a module so Python's import resolution picks up the app/ package.
CMD ["python", "-m", "app.app"]
