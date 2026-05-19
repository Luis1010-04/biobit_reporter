import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:csv/csv.dart';
import 'models.dart';

class InfluxService {
  final Dio _dio = Dio();

  // Configuración de endpoints y credenciales proporcionadas
  final String openWebUiUrl = 'http://163.192.137.93:8080/api/v1/chat/completions';
  final String openWebUiToken = 'sk-86021b4ba08f4fd48e053e02c77a8b18';
  final String influxUrl = 'http://163.192.137.93:8086/api/v2/query?org=ITESHU-biobit';
  final String influxToken = 'vyUOGMMbBkkz__6Z8c4UMVf-fU3FibiCoaxQC6WSbiFt-b_wZOColfR_hD410V5UBCm8rDCYaRWrlDEIhw7yiQ==';

  /// Envía el mensaje del usuario al modelo 'analista-influx' en Open WebUI
  Future<IaResponse> translateNaturalLanguage(String userMessage) async {
    try {
      print('=== [PASO 1] Enviando a Open WebUI: "$userMessage" ===');
      
      final response = await _dio.post(
        openWebUiUrl,
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $openWebUiToken',
          },
        ),
        data: {
          'model': 'analista-influx',
          'messages': [
            {'role': 'user', 'content': userMessage}
          ],
          'temperature': 0.1,
        },
      );

      print('=== [PASO 2] Respuesta de Open WebUI recibida ===');
      final decodedBody = response.data;
      final String assistantContent = decodedBody['choices'][0]['message']['content'].toString().trim();
      
      print('JSON crudo de la IA: $assistantContent'); // <-- AQUÍ VEREMOS SI LA IA SE EQUIVOCÓ
      
      return IaResponse.fromJson(jsonDecode(assistantContent));
    } catch (e) {
      print('❌ ERROR EN OPEN WEBUI: $e');
      throw Exception('Error en traducción de IA: $e');
    }
  }

Future<List<InfluxRecord>> queryInfluxDB(String fluxQuery) async {
    try {
print('=== [PASO 3] Enviando Query a InfluxDB (Estrategia Comillas Dobles) ===');

// 1. Tu limpieza actual...
String sanitizedQuery = fluxQuery.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
sanitizedQuery = sanitizedQuery
    .replaceAll("'", '"')
    .replaceAll("‘", '"')
    .replaceAll("’", '"')
    .replaceAll("“", '"')
    .replaceAll("”", '"')
    .replaceAll("`", '"')
    .replaceAll("´", '"');

// 2. Conversión a bytes
Uint8List bodyBytes = utf8.encode(sanitizedQuery);

// ==========================================
// 🔥 TRUCO DE DEPURACIÓN SENIOR PARA CONSOLA
// ==========================================
// Esto vuelve a decodificar los bytes puros que van por la red para que veas la verdad absoluta
String queryRealEnCamino = utf8.decode(bodyBytes);
print('🚀 TEXTO EXACTO EN EL PAYLOAD HTTP:');
print('--------------------------------------------------');
print(queryRealEnCamino);
print('--------------------------------------------------');
print('📦 Tamaño del Payload: ${bodyBytes.length} bytes');
// ==========================================

final response = await _dio.post(
  influxUrl,
  options: Options(
    headers: {
      'Authorization': 'Token $influxToken',
      'Content-Type': 'application/vnd.flux; charset=utf-8',
      'Accept': 'application/csv',
    },
    responseType: ResponseType.plain,
  ),
  data: bodyBytes, // Enviando el stream directo
);

// ==========================================
      // 🛠️ AUDITORÍA VISUAL DEL CSV EN CRUDO
      // ==========================================
      print('📄 RESPUESTA EN CRUDO DESDE EL SERVIDOR (CSV):');
      print('--------------------------------------------------');
      print(response.data);
      print('--------------------------------------------------');
      // ==========================================

      return _parseInfluxCsv(response.data.toString());
    } catch (e) {
      print('❌ ERROR CRÍTICO EN INFLUXDB:');
      if (e is DioException) {
        print('Status Code: ${e.response?.statusCode}');
        print('Cuerpo del error del servidor: ${e.response?.data}');
      } else {
        print('Error genérico: $e');
      }
      throw Exception('Error de conexión con InfluxDB: $e');
    }
  }
  /// Procesa las líneas del Annotated CSV y las convierte en objetos InfluxRecord
  List<InfluxRecord> _parseInfluxCsv(String csvRawData) {
  final List<InfluxRecord> records = [];
  
  // Dividimos la respuesta por saltos de línea limpiando retornos de carro
  final List<String> lines = csvRawData.split('\n');
  if (lines.isEmpty) return records;

  // Identificamos la línea de cabeceras para mapear dinámicamente los índices
  final String headerLine = lines.firstWhere(
    (line) => line.contains('_time') && line.contains('_value'),
    orElse: () => '',
  );

  if (headerLine.isEmpty) return records;

  final List<String> headers = headerLine.split(',').map((h) => h.trim()).toList();
  
  // Localizamos los índices exactos de las columnas clave
  final int timeIndex = headers.indexOf('_time');
  final int valueIndex = headers.indexOf('_value');
  final int fieldIndex = headers.indexOf('_field');
  final int deviceIndex = headers.indexOf('dispositivo');

  // Si no se encuentran las columnas esenciales, abortamos para evitar excepciones
  if (timeIndex == -1 || valueIndex == -1 || fieldIndex == -1) return records;

  for (var line in lines) {
    final trimmedLine = line.trim();
    // Saltamos las líneas vacías, comentarios o la misma cabecera
    if (trimmedLine.isEmpty || trimmedLine.startsWith('#') || trimmedLine == headerLine) {
      continue;
    }

    final List<String> cells = trimmedLine.split(',').map((c) => c.trim()).toList();
    
    // Verificamos que la línea tenga suficientes columnas según el mapeo de cabeceras
    if (cells.length > timeIndex && cells.length > valueIndex && cells.length > fieldIndex) {
      try {
        final String timeStr = cells[timeIndex];
        final double? value = double.tryParse(cells[valueIndex]);
        final String field = cells[fieldIndex];
        final String device = deviceIndex != -1 && cells.length > deviceIndex ? cells[deviceIndex] : 'unknown';

        if (value != null && timeStr.isNotEmpty) {
          records.add(InfluxRecord(
            time: DateTime.parse(timeStr).toLocal(),
            value: value,
            field: field,
            dispositivo: device, // ✨ CAMBIADO: de 'device:' a 'dispositivo:' para que coincida con tu clase
          ));
        }
      } catch (e) {
        print('⚠️ Error parseando línea CSV: $e');
      }
    }
  }

  print('📊 Registros procesados con éxito en Flutter: ${records.length}');
  return records;
}
}