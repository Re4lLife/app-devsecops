FROM node:12.13.1-alpine AS builder

WORKDIR /usr/src/app


COPY package.json ./


RUN npm install


FROM node:12.13.1-alpine

WORKDIR /usr/src/app

COPY --from=builder /usr/src/app/node_modules ./node_modules

COPY package.json ./

COPY server.js ./
COPY public/ ./public/

EXPOSE 3000
CMD ["npm", "start"]