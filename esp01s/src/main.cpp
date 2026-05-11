#include <Arduino.h>
#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ElegantOTA.h>
#include "secrets.h"

#define LED_PIN 1

ESP8266WebServer server(80);

unsigned long lastBlink = 0;
bool ledState = false;

void setup() {
    pinMode(LED_PIN, OUTPUT);
    digitalWrite(LED_PIN, HIGH);

    WiFi.begin(ssid, password);
    while (WiFi.status() != WL_CONNECTED) {
        delay(500);
        digitalWrite(LED_PIN, !digitalRead(LED_PIN));
    }

    ElegantOTA.begin(&server);
    server.begin();
    Serial.begin(115200);
    Serial.println("ESP-01S echo test ready");

}

void loop() {
    server.handleClient();
    ElegantOTA.loop();

    if (Serial.available()) {
        char c = Serial.read();
        Serial.write(c);
    }
}
