FROM node:22

WORKDIR /app

# Copy package files first (better layer caching)
COPY ./package*.json ./

RUN npm install --omit=dev

# Copy the rest of the app source
COPY src/ ./src/

# add newest certificate
RUN curl -o rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

# expose port
EXPOSE 3000

# Start the Node app
CMD ["node", "src/app.js"]