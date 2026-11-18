#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <PubSubClient.h>
#include <HTTPClient.h>
#include <NetworkClientSecure.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

const char* WIFI_SSID     = "Nokia";
const char* WIFI_PASSWORD = "Password";

#define UV_SENSOR_PIN 2
#define I2C_SDA_PIN   8
#define I2C_SCL_PIN   9
#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
WebServer server(80);
WiFiClient espClient;
PubSubClient mqttClient(espClient);

const char* MQTT_BROKER   = "broker.hivemq.com";
const int   MQTT_PORT     = 1883;
const char* MQTT_TOPIC    = "venkat_iot/sensors/uv/node_01";
const char* DEVICE_ID     = "ESP32_node_01";

#define INFLUXDB_URL    "https://us-east-1-1.aws.cloud2.influxdata.com/api/v2/write?org=IOT&bucket=uv_sensor_data&precision=s"
#define INFLUXDB_TOKEN  "Dbzt7IHP3G4E4McgOmsRBrZLUaK2fsEgexNVFzYSQI1V2PhqWbL6SFhB64Vg-jOY6HQIu7BibH8jkSQvHqLNWw=="

#define MEDIAN_WIN_SIZE 9
float winBuf[MEDIAN_WIN_SIZE];
int winCount = 0;
int winIdx   = 0;

bool filterInitialized = false;
float kalX = 0.0f, kalP = 1.0f;
float hybX = 0.0f, hybP = 1.0f;

unsigned long lastSampleMillis = 0;
const unsigned long SAMPLE_INTERVAL_MS = 500;
uint32_t packetSeq = 0;

float currentMvRaw    = 0.0f;
float currentMvMedian = 0.0f;
float currentMvKalman = 0.0f;
float currentMvHybrid = 0.0f;
float currentUvIndex  = 0.0f;
String currentRisk    = "Low";
int currentRssi       = 0;

// Expanded 0-4500mV Sunlight Scale so direct sun doesn't peg at 12 immediately
const float UVI_THRESHOLDS[12] = {
  128.0f, 680.0f, 980.0f, 1300.0f, 1650.0f, 2000.0f,
  2350.0f, 2700.0f, 3050.0f, 3400.0f, 3800.0f, 4150.0f
};

float getCalibratedUVI(float mv) {
  if (mv < UVI_THRESHOLDS[0]) return 0.0f;
  if (mv >= UVI_THRESHOLDS[11]) {
    float finalSlope = (11.0f - 10.0f) / (UVI_THRESHOLDS[11] - UVI_THRESHOLDS[10]);
    float uvi = 11.0f + ((mv - UVI_THRESHOLDS[11]) * finalSlope);
    return (uvi > 12.0f) ? 12.0f : uvi;
  }
  for (int i = 0; i < 11; i++) {
    if (mv >= UVI_THRESHOLDS[i] && mv <= UVI_THRESHOLDS[i+1]) {
      return i + ((mv - UVI_THRESHOLDS[i]) / (UVI_THRESHOLDS[i+1] - UVI_THRESHOLDS[i]));
    }
  }
  return 0.0f;
}

String getRiskCategory(float uvi) {
  if (uvi < 3.0f)  return "Low";
  if (uvi < 6.0f)  return "Moderate";
  if (uvi < 8.0f)  return "High";
  if (uvi < 11.0f) return "Very high";
  return "Extreme";
}

String getShortOledRisk(float uvi) {
  if (uvi < 3.0f)  return "Low";
  if (uvi < 6.0f)  return "Mod";
  if (uvi < 8.0f)  return "High";
  if (uvi < 11.0f) return "V.High";
  return "Extreme";
}

float readAveragedMilliVolts() {
  uint32_t totalMv = 0;
  for (int i = 0; i < 32; i++) {
    totalMv += analogReadMilliVolts(UV_SENSOR_PIN);
    delayMicroseconds(250);
  }
  return (totalMv / 32.0f);
}

void updateFiltersAndSensors() {
  float raw = readAveragedMilliVolts();
  if (raw < UVI_THRESHOLDS[0]) raw = 0.0f;
  float clampedRaw = constrain(raw, 0.0f, 4500.0f);
  currentMvRaw = clampedRaw;

  winBuf[winIdx] = clampedRaw;
  winIdx = (winIdx + 1) % MEDIAN_WIN_SIZE;
  if (winCount < MEDIAN_WIN_SIZE) winCount++;

  float sorted[MEDIAN_WIN_SIZE];
  for (int i = 0; i < winCount; i++) sorted[i] = winBuf[i];
  for (int i = 0; i < winCount - 1; i++) {
    for (int j = i + 1; j < winCount; j++) {
      if (sorted[j] < sorted[i]) {
        float tmp = sorted[i]; sorted[i] = sorted[j]; sorted[j] = tmp;
      }
    }
  }
  currentMvMedian = sorted[winCount / 2];

  if (clampedRaw == 0.0f && currentMvMedian == 0.0f) {
    kalX = 0.0f;
    hybX = 0.0f;
  } else if (!filterInitialized) {
    kalX = clampedRaw;
    hybX = currentMvMedian;
    filterInitialized = true;
  } else {
    kalP += 0.05f;
    float kG = kalP / (kalP + 1.0f);
    kalX += kG * (clampedRaw - kalX);
    kalP = (1.0f - kG) * kalP;

    hybP += 0.05f;
    float hG = hybP / (hybP + 1.5f);
    hybX += hG * (currentMvMedian - hybX);
    hybP = (1.0f - hG) * hybP;
  }

  currentMvKalman = constrain(kalX, 0.0f, 4500.0f);
  currentMvHybrid = constrain(hybX, 0.0f, 4500.0f);

  if (currentMvHybrid < UVI_THRESHOLDS[0]) {
    currentMvHybrid = 0.0f;
    currentMvRaw    = 0.0f;
    currentMvMedian = 0.0f;
    currentMvKalman = 0.0f;
  }

  currentUvIndex = getCalibratedUVI(currentMvHybrid);
  currentRisk    = getRiskCategory(currentUvIndex);
  currentRssi    = WiFi.RSSI();
}

void handleJsonData() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "*");

  JsonDocument doc;
  doc["seq"]                = packetSeq;
  doc["device_id"]          = DEVICE_ID;
  doc["mv_raw"]             = serialized(String(currentMvRaw, 2));
  doc["mv_median"]          = serialized(String(currentMvMedian, 2));
  doc["mv_kalman"]          = serialized(String(currentMvKalman, 2));
  doc["mv_hybrid"]          = serialized(String(currentMvHybrid, 2));
  doc["uv_index_estimated"] = serialized(String(currentUvIndex, 3));
  doc["risk_category"]      = currentRisk;
  doc["rssi_dbm"]           = currentRssi;
  doc["ip"]                 = WiFi.localIP().toString();

  String response;
  serializeJson(doc, response);
  server.send(200, "application/json", response);
}

void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setTxPower(WIFI_POWER_8_5dBm);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Connecting Wi-Fi...");
    display.display();
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println("Connected!");
  display.display();
  delay(1500);
}

void publishToInfluxDb() {
  if (WiFi.status() != WL_CONNECTED) return;
  static int cloudSyncCounter = 0;
  cloudSyncCounter++;
  if (cloudSyncCounter < 5) return;
  cloudSyncCounter = 0;

  NetworkClientSecure client;
  client.setInsecure();
  HTTPClient https;

  if (https.begin(client, INFLUXDB_URL)) {
    https.addHeader("Authorization", "Token " + String(INFLUXDB_TOKEN));
    https.addHeader("Content-Type", "text/plain; charset=utf-8");

    String lineProtocol = String("uv_measurement,device=") + DEVICE_ID + " ";
    lineProtocol += "voltage_raw_mv=" + String(currentMvRaw, 2) + ",";
    lineProtocol += "voltage_median_mv=" + String(currentMvMedian, 2) + ",";
    lineProtocol += "voltage_kalman_mv=" + String(currentMvKalman, 2) + ",";
    lineProtocol += "voltage_hybrid_mv=" + String(currentMvHybrid, 2) + ",";
    lineProtocol += "uv_index_estimated=" + String(currentUvIndex, 3);

    https.POST(lineProtocol);
    https.end();
  }
}

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);
  analogSetPinAttenuation(UV_SENSOR_PIN, ADC_11db);

  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);

  connectWiFi();

  server.on("/data", HTTP_GET, handleJsonData);
  server.on("/data", HTTP_OPTIONS, []() {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.send(204);
  });
  server.begin();

  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
  mqttClient.setBufferSize(512);
}

void loop() {
  server.handleClient();
  if (WiFi.status() != WL_CONNECTED) connectWiFi();
  if (!mqttClient.connected()) {
    String clientId = String(DEVICE_ID) + "_" + String(random(0xffff), HEX);
    mqttClient.connect(clientId.c_str());
  }
  mqttClient.loop();

  unsigned long now = millis();
  if (now - lastSampleMillis >= SAMPLE_INTERVAL_MS) {
    lastSampleMillis = now;
    packetSeq++;

    updateFiltersAndSensors();

    JsonDocument doc;
    doc["seq"]                = packetSeq;
    doc["device_id"]          = DEVICE_ID;
    doc["mv_raw"]             = serialized(String(currentMvRaw, 2));
    doc["mv_median"]          = serialized(String(currentMvMedian, 2));
    doc["mv_kalman"]          = serialized(String(currentMvKalman, 2));
    doc["mv_hybrid"]          = serialized(String(currentMvHybrid, 2));
    doc["uv_index_estimated"] = serialized(String(currentUvIndex, 3));
    doc["risk_category"]      = currentRisk;
    doc["rssi_dbm"]           = currentRssi;

    char jsonBuffer[384];
    serializeJson(doc, jsonBuffer);
    mqttClient.publish(MQTT_TOPIC, jsonBuffer);

    publishToInfluxDb();

    String oledRisk = getShortOledRisk(currentUvIndex);
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.printf("IP:%s\n", WiFi.localIP().toString().c_str());
    display.println("--------------------");
    display.printf("Hyb mV: %.2f\n", currentMvHybrid);
    display.printf("UV Idx: %.2f (%s)\n", currentUvIndex, oledRisk.c_str());
    display.printf("RSSI:   %d dBm (#%lu)\n", currentRssi, packetSeq);
    display.display();
  }
}