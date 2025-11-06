FROM elixir:1.15-alpine

# Install dependencies
RUN apk add --no-cache \
    build-base \
    git \
    curl \
    openssl

# Create app directory
WORKDIR /app

# Copy mix files
COPY mix.exs mix.lock ./

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies
RUN mix deps.get && \
    mix deps.compile

# Copy application code
COPY . .

# Compile application
RUN mix compile

# Expose ports
EXPOSE 4000 9092

CMD ["mix", "run", "--no-halt"]

