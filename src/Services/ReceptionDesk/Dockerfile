FROM elixir:1.19.5-otp-28@sha256:d170fadffd75b36146ff40b6e8d5cc881c59d136ae5a2c34a1b394ec33b6cffa AS build
ENV MIX_ENV=prod
WORKDIR /app/src/Services/ReceptionDesk
RUN mix local.hex --force && mix local.rebar --force
COPY src/Services/ReceptionDesk/mix.exs src/Services/ReceptionDesk/mix.lock ./
COPY src/Services/ReceptionDesk/config ./config
RUN mix deps.get --only prod && mix deps.compile
COPY src/Services/ReceptionDesk/lib ./lib
COPY src/Services/ReceptionDesk/relay_src ./relay_src
RUN mix compile --warnings-as-errors && mix release --path /release
RUN mkdir -p /release/licenses && for dep in /app/builds/intermediates/ReceptionDeskDeps/*; do \
    for file in "$dep"/LICENSE*; do if [ -f "$file" ]; then \
    cp "$file" "/release/licenses/$(basename "$dep")-$(basename "$file")"; fi; done; done

FROM elixir:1.19.5-otp-28@sha256:d170fadffd75b36146ff40b6e8d5cc881c59d136ae5a2c34a1b394ec33b6cffa
WORKDIR /app
COPY --from=build --chown=1000:1000 /release ./
RUN mkdir -p /app/tmp && chown 1000:1000 /app /app/tmp
USER 1000:1000
ENV HOME=/app PARVI_BROKER_BIND=0.0.0.0 PORT=10000 RELEASE_DISTRIBUTION=none RELEASE_TMP=/app/tmp
EXPOSE 10000
CMD ["/app/bin/reception_desk", "start"]
