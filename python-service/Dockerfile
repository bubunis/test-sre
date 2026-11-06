FROM python:3.11-slim

WORKDIR /app

# Install uv (the package manager used in this project)
RUN pip install uv

# Copy the dependency files first
COPY pyproject.toml uv.lock ./

# Install dependencies into the system python environment
RUN uv pip install --system -r pyproject.toml

# Copy the application code
COPY . .

# Expose the FastAPI port
EXPOSE 8000

# Start the uvicorn server
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]