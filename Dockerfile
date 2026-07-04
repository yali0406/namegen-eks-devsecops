## Dockerfile for the namegen (Random Name Generator and Saver) app
## Base source: https://github.com/redhat-developer-demos/namegen
## Place this file in the ROOT of the cloned namegen source code before building.

FROM node:18-alpine AS base

# Create app directory
WORKDIR /usr/src/app

# Install dependencies first (better layer caching)
COPY package*.json ./
RUN npm install --omit=dev

# Copy application source
COPY . .

# The app reads MONGODB_URL and SERVER_PORT from environment variables (see .env / server.js)
ENV SERVER_PORT=8080
EXPOSE 8080

# Run as the non-root "node" user provided by the base image
USER node

CMD ["node", "server.js"]
