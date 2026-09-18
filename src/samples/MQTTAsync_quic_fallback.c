/*******************************************************************************
 * Copyright (c) 2023-2025 EMQ Technologies Co., William Yang and others.
 *
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the Eclipse Public License v2.0
 * and Eclipse Distribution License v1.0 which accompany this distribution.
 *
 * The Eclipse Public License is available at
 *    https://www.eclipse.org/legal/epl-2.0/
 * and the Eclipse Distribution License is available at
 *   http://www.eclipse.org/org/documents/edl-v10.php.
 *
 * MQTT over QUIC with fallback to TLS, using the serverURIs option.
 *
 * The client tries quic:// first and falls back to ssl:// when the QUIC
 * connection cannot be established (e.g. UDP is blocked).  Note that a
 * blocked/dead QUIC port fails by timeout, not immediately: expect up to
 * ~30 seconds per URI before the fallback kicks in (bounded by
 * connectTimeout and the QUIC handshake timeout), and with
 * MQTTVERSION_DEFAULT each URI is retried once per MQTT protocol version,
 * so setting an explicit version halves the failover time.
*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "MQTTAsync.h"

#if !defined(_WIN32)
#include <unistd.h>
#else
#include <windows.h>
#endif

#if defined(_WRS_KERNEL)
#include <OsWrapper.h>
#endif

#define QUIC_ADDRESS  "quic://127.0.0.1:14567"
#define SSL_ADDRESS   "ssl://127.0.0.1:8883"
#define CLIENTID      "ExampleClientPubFallback"
#define TOPIC         "MQTT Examples"
#define PAYLOAD       "Hello World!"
#define QOS           1
#define TIMEOUT       10000L

int finished = 0;

void connlost(void *context, char *cause)
{
	printf("\nConnection lost\n");
	printf("     cause: %s\n", cause);
	finished = 1;
}

void onDisconnectFailure(void* context, MQTTAsync_failureData* response)
{
	printf("Disconnect failed\n");
	finished = 1;
}

void onDisconnect(void* context, MQTTAsync_successData* response)
{
	printf("Successful disconnection\n");
	finished = 1;
}

void onSendFailure(void* context, MQTTAsync_failureData* response)
{
	printf("Message send failed token %d error code %d\n", response->token, response->code);
	finished = 1;
}

void onSend(void* context, MQTTAsync_successData* response)
{
	MQTTAsync client = (MQTTAsync)context;
	MQTTAsync_disconnectOptions opts = MQTTAsync_disconnectOptions_initializer;
	int rc;

	printf("Message with token value %d delivery confirmed\n", response->token);
	opts.onSuccess = onDisconnect;
	opts.onFailure = onDisconnectFailure;
	opts.context = client;
	if ((rc = MQTTAsync_disconnect(client, &opts)) != MQTTASYNC_SUCCESS)
	{
		printf("Failed to start disconnect, return code %d\n", rc);
		exit(EXIT_FAILURE);
	}
}

void onConnectFailure(void* context, MQTTAsync_failureData* response)
{
	printf("Connect failed on all serverURIs, rc %d\n", response ? response->code : 0);
	finished = 1;
}

void onConnect(void* context, MQTTAsync_successData* response)
{
	MQTTAsync client = (MQTTAsync)context;
	MQTTAsync_responseOptions opts = MQTTAsync_responseOptions_initializer;
	MQTTAsync_message pubmsg = MQTTAsync_message_initializer;
	int rc;

	printf("Successful connection via %s\n", response->alt.connect.serverURI);
	opts.onSuccess = onSend;
	opts.onFailure = onSendFailure;
	opts.context = client;
	pubmsg.payload = PAYLOAD;
	pubmsg.payloadlen = (int)strlen(PAYLOAD);
	pubmsg.qos = QOS;
	pubmsg.retained = 0;
	if ((rc = MQTTAsync_sendMessage(client, TOPIC, &pubmsg, &opts)) != MQTTASYNC_SUCCESS)
	{
		printf("Failed to start sendMessage, return code %d\n", rc);
		exit(EXIT_FAILURE);
	}
}

int messageArrived(void* context, char* topicName, int topicLen, MQTTAsync_message* m)
{
	/* not expecting any messages */
	return 1;
}

int main(int argc, char* argv[])
{
	MQTTAsync client;
	MQTTAsync_connectOptions conn_opts = MQTTAsync_connectOptions_initializer;
	MQTTAsync_SSLOptions sslopts = MQTTAsync_SSLOptions_initializer;
	sslopts.enableServerCertAuth = 0; //for simplicity, we don't verify the server certificate
	char* uris[2];
	int rc;

	const char* quic_uri = (argc > 1) ? argv[1] : QUIC_ADDRESS;
	const char* ssl_uri = (argc > 2) ? argv[2] : SSL_ADDRESS;
	const char* username = (argc > 3) ? argv[3] : NULL;
	const char* password = (argc > 4) ? argv[4] : NULL;

	uris[0] = (char*)quic_uri;  /* tried first */
	uris[1] = (char*)ssl_uri;   /* fallback */

	if ((rc = MQTTAsync_create(&client, quic_uri, CLIENTID, MQTTCLIENT_PERSISTENCE_NONE, NULL)) != MQTTASYNC_SUCCESS)
	{
		printf("Failed to create client object, return code %d\n", rc);
		exit(EXIT_FAILURE);
	}

	if ((rc = MQTTAsync_setCallbacks(client, NULL, connlost, messageArrived, NULL)) != MQTTASYNC_SUCCESS)
	{
		printf("Failed to set callback, return code %d\n", rc);
		exit(EXIT_FAILURE);
	}

	conn_opts.keepAliveInterval = 20;
	conn_opts.cleansession = 1;
	conn_opts.username = username;
	conn_opts.password = password;
	conn_opts.serverURIs = uris;
	conn_opts.serverURIcount = 2;
	conn_opts.MQTTVersion = MQTTVERSION_3_1_1; /* avoid a second attempt per URI with MQTT 3.1 */
	conn_opts.connectTimeout = 10;           /* each URI is tried for up to 10s */
	conn_opts.onSuccess = onConnect;
	conn_opts.onFailure = onConnectFailure;
	conn_opts.context = client;
	conn_opts.ssl = &sslopts;
	if ((rc = MQTTAsync_connect(client, &conn_opts)) != MQTTASYNC_SUCCESS)
	{
		printf("Failed to start connect, return code %d\n", rc);
		exit(EXIT_FAILURE);
	}

	printf("Trying %s, falling back to %s\n", quic_uri, ssl_uri);
	while (!finished)
		#if defined(_WIN32)
			Sleep(100);
		#else
			usleep(10000L);
		#endif

	MQTTAsync_destroy(&client);
 	return rc;
}
