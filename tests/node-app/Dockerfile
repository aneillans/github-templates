FROM node:24-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
# exercises the template's build_args and build_secrets inputs
ARG APP_VERSION=0.0.0-dev
ENV APP_VERSION=$APP_VERSION
RUN --mount=type=secret,id=test_secret test ! -e /run/secrets/test_secret || test -s /run/secrets/test_secret
COPY app.js server.js ./
USER node
EXPOSE 3000
CMD ["node", "server.js"]
