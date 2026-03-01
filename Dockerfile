FROM ruby:4.0.1-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    git \
    curl \
    ca-certificates \
    libomp-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --recursive --branch v4.3.0 --depth 1 https://github.com/microsoft/LightGBM.git /tmp/LightGBM \
    && cmake -S /tmp/LightGBM -B /tmp/LightGBM/build -DUSE_OPENMP=ON \
    && cmake --build /tmp/LightGBM/build -j"$(nproc)" \
    && cp /tmp/LightGBM/lightgbm /usr/local/bin/lightgbm \
    && rm -rf /tmp/LightGBM

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

CMD ["ruby", "app/main.rb"]
