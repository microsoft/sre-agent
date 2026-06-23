FROM node:20-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./
EXPOSE 8080
ENV PORT=8080
USER node
CMD ["node", "server.js"]
