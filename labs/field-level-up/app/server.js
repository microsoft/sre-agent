'use strict';

const { createTelemetry } = require('./telemetry');

let telemetry;
if (process.env.APPLICATIONINSIGHTS_CONNECTION_STRING) {
  try {
    telemetry = createTelemetry(process.env.APPLICATIONINSIGHTS_CONNECTION_STRING,
      require('applicationinsights'));
  } catch {
    console.warn('Telemetry initialization unavailable. The lab will continue without telemetry.');
  }
}

const { createServer } = require('node:http');
const { Client } = require('pg');
const { ManagedIdentityCredential } = require('@azure/identity');
const { createHandler } = require('./handler');

const credential = new ManagedIdentityCredential({ clientId: process.env.AZURE_CLIENT_ID });
const server = createServer(createHandler({
  createClient: (config) => new Client(config), telemetry,
  getAccessToken: (scope) => credential.getToken(scope),
}));
server.requestTimeout = 10000;
server.headersTimeout = 10000;
server.keepAliveTimeout = 5000;
server.listen(Number(process.env.PORT || 8080), '0.0.0.0', () => {
  console.info('Simulated checkout lab listening. No database connection is required for startup.');
});