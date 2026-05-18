import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'dart:convert';
import 'dart:math' as math;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Biobit AI Dashboard',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1E3A8A), // Azul marino ejecutivo
          background: const Color(0xFFF8FAFC), // Fondo ultra claro moderno (slate-50)
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  bool _isLoading = false;

  // Endpoint de OpenWebUI (Actúa como nuestro compilador de intenciones a JSON)
  final String openWebUiUrl = 'http://163.192.137.93:8080/api/v1/chat/completions';
  final String openWebUiKey = 'sk-86021b4ba08f4fd48e053e02c77a8b18';

  // Endpoint Directo de InfluxDB para la ejecución segura de las queries generadas
  final String influxUrl = 'http://163.192.137.93:8086/api/v2/query?org=ITESHU-biobit';
  final String influxToken = 'vyUOGMMbBkkz__6Z8c4UMVf-fU3FibiCoaxQC6WSbiFt-b_wZOColfR_hD410V5UBCm8rDCYaRWrlDEIhw7yiQ==';

  /// LÓGICA DE NEGOCIO: Consulta directa a InfluxDB usando la query inyectada por la IA
  Future<List<Map<String, dynamic>>?> _executeFluxOnInflux(String fluxQuery) async {
    final dio = Dio();
    try {
      print('🛰️ Ejecutando Query Flux compilada por la IA en InfluxDB...');
      final response = await dio.post(
        influxUrl,
        data: fluxQuery,
        options: Options(
          headers: {
            'Authorization': 'Token $influxToken',
            'Content-Type': 'application/vnd.flux',
            'Accept': 'application/csv',
          },
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return _pivotInfluxCSV(response.data.toString());
      }
    } catch (e) {
      print('❌ Error de ejecución en el motor InfluxDB: $e');
    }
    return null;
  }

  /// ALGORITMO: Transposición Matricial / Pivoteo de CSV a JSON de UI
  List<Map<String, dynamic>> _pivotInfluxData(String csvData) {
    Map<String, Map<String, dynamic>> groupedByTime = {};
    List<String> lines = csvData.split('\n');
    
    for (String line in lines) {
      if (line.trim().isEmpty || line.startsWith('#') || line.startsWith(',result')) continue;
      
      List<String> columns = line.split(',');
      if (columns.length >= 8) {
        try {
          String rawTime = columns[5].trim();
          DateTime utcDateTime = DateTime.parse(rawTime);
          DateTime mexicoDateTime = utcDateTime.subtract(const Duration(hours: 6)); // Ajuste de zona horaria de México
          String formattedTime = "${mexicoDateTime.year}-${mexicoDateTime.month.toString().padLeft(2, '0')}-${mexicoDateTime.day.toString().padLeft(2, '0')} ${mexicoDateTime.hour.toString().padLeft(2, '0')}:${mexicoDateTime.minute.toString().padLeft(2, '0')}:${mexicoDateTime.second.toString().padLeft(2, '0')}";

          // CORRECCIÓN CLAVE DE COLUMNAS: columns[7] es _field (sensor), columns[6] es _value (métrica)
          String fieldName = columns[7].trim();
          String valueRaw = columns[6].trim();
          double value = double.tryParse(valueRaw) ?? 0.0;

          if (!groupedByTime.containsKey(formattedTime)) {
            groupedByTime[formattedTime] = {
              'fecha_hora': formattedTime,
            };
          }
          groupedByTime[formattedTime]![fieldName] = value;
        } catch (_) {}
      }
    }

    List<Map<String, dynamic>> list = groupedByTime.values.toList();
    list.sort((a, b) => b['fecha_hora'].toString().compareTo(a['fecha_hora'].toString()));
    return list;
  }

  List<Map<String, dynamic>> _pivotInfluxCSV(String csvData) {
    return _pivotInfluxData(csvData);
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add({'role': 'user', 'content': text});
      _isLoading = true;
    });
    _controller.clear();

    try {
      final dio = Dio();
      
      // Construimos el historial conversacional estándar para pasarle a OpenWebUI
      List<Map<String, dynamic>> apiMessages = [];
      for (var m in _messages) {
        // Limpiamos referencias JSON de ciclos pasados para no ensuciar la ventana de contexto
        if (m.containsKey('content') && m['content'] != null) {
          apiMessages.add({'role': m['role'], 'content': m['content']});
        }
      }

      // 1. LLAMADA DIRECTA AL COMPILADOR DE OPENWEBUI
      final response = await dio.post(
        openWebUiUrl,
        data: {
          'model': 'analista-influx',
          'messages': apiMessages,
          'temperature': 0.0, // Forzamos determinismo absoluto (Cero creatividad)
          'tool_ids': [], // Desactivamos tools nativas; la IA ahora es un compilador puro
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $openWebUiKey',
            'Content-Type': 'application/json',
          },
        ),
      );

      final String aiRawResponse = response.data['choices'][0]['message']['content'].toString().trim();
      print('📥 JSON Crudo recibido de OpenWebUI:\n$aiRawResponse');

      // 2. PARSEO SEGURO DEL COMPILADOR JSON
      Map<String, dynamic> parsedAiJson;
      try {
        parsedAiJson = jsonDecode(aiRawResponse);
      } catch (e) {
        // Contingencia por si la IA llega a meter markdown por error
        final jsonRegex = RegExp(r'```json([\s\S]*?)```');
        final match = jsonRegex.firstMatch(aiRawResponse);
        if (match != null) {
          parsedAiJson = jsonDecode(match.group(1)!.trim());
        } else {
          throw Exception("Formato de respuesta lingüística inválido.");
        }
      }

      List<Map<String, dynamic>>? databaseRecords;
      
      // 3. CAPA DE CONTROL DE ACCIONES: ¿Requiere base de datos?
      if (parsedAiJson['action'] == 'query_db' && parsedAiJson['flux_query'] != null) {
        databaseRecords = await _executeFluxOnInflux(parsedAiJson['flux_query']);
      }

      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': parsedAiJson['assistant_comment'] ?? 'Procesado con éxito.',
          'visual_type': parsedAiJson['visual_type'] ?? 'none',
          'telemetry_data': databaseRecords,
        });
      });

    } catch (e) {
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': '⚠️ Error en la pasarela de control inteligente: No se pudo procesar la intención del prompt.',
          'visual_type': 'none'
        });
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.colorScheme.background,
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.analytics_rounded, color: theme.colorScheme.primary),
            ),
            const SizedBox(width: 12),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Biobit AI',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Color(0xFF1E293B)),
                ),
                Text(
                  'Dashboard Analítico',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),
          ],
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: Colors.grey.shade200, height: 1.0),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isUser = msg['role'] == 'user';
                final String visualType = msg['visual_type'] ?? 'none';
                final List<Map<String, dynamic>>? records = msg['telemetry_data'] != null
                    ? List<Map<String, dynamic>>.from(msg['telemetry_data'])
                    : null;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10.0),
                  child: Column(
                    crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      // Globo Conversacional Moderno
                      Align(
                        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: isUser 
                                ? theme.colorScheme.primary 
                                : Colors.white,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(16),
                              topRight: const Radius.circular(16),
                              bottomLeft: isUser ? const Radius.circular(16) : const Radius.circular(4),
                              bottomRight: isUser ? const Radius.circular(4) : const Radius.circular(16),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.03),
                                blurRadius: 6,
                                offset: const Offset(0, 3),
                              )
                            ],
                            border: isUser ? null : Border.all(color: Colors.grey.shade100),
                          ),
                          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.82),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isUser ? Icons.account_circle : Icons.psychology,
                                    size: 14,
                                    color: isUser ? Colors.white70 : theme.colorScheme.primary,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isUser ? 'Tú' : 'Analista Biobit',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold, 
                                      fontSize: 11,
                                      color: isUser ? Colors.white70 : theme.colorScheme.primary,
                                      letterSpacing: 0.5
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                msg['content'] ?? '',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isUser ? Colors.white : const Color(0xFF334155),
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                      // FABRICANTE DINÁMICO DE COMPONENTES VISUALES EN ALTA CALIDAD
                      if (records != null && records.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.95),
                            child: _renderUiComponent(visualType, records),
                          ),
                        ),
                      ]
                    ],
                  ),
                );
              },
            ),
          ),
          if (_isLoading)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.colorScheme.primary.withOpacity(0.1)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '🧠 Compilando orden y analizando base de datos...',
                    style: TextStyle(
                      color: theme.colorScheme.primary, 
                      fontSize: 12, 
                      fontWeight: FontWeight.bold
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(12.0),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Ej: Grafícame la temperatura de la última hora...',
                      hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: Colors.grey.shade200),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: Colors.grey.shade100),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide(color: theme.colorScheme.primary.withOpacity(0.3)),
                      ),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: theme.colorScheme.primary,
                  radius: 20,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 16),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// RENDER COMPONENT HUB: Elige y construye el Widget exacto solicitado por la IA
  Widget _renderUiComponent(String type, List<Map<String, dynamic>> data) {
    switch (type) {
      case 'data_table':
        return _buildDataTable(data);
      case 'line_chart':
        return TelemetryChartWidget(type: 'line_chart', dataList: data);
      case 'histogram':
        return TelemetryChartWidget(type: 'histogram', dataList: data);
      default:
        return _buildDataTable(data);
    }
  }

  /// COMPONENTE 1: Generador Dinámico de Tablas con Diseño Ejecutivo
  Widget _buildDataTable(List<Map<String, dynamic>> dataList) {
    final theme = Theme.of(context);
    List<String> headers = ['fecha_hora'];
    for (var row in dataList) {
      for (var key in row.keys) {
        if (!headers.contains(key)) headers.add(key);
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabecera elegante de la Tabla
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.grey.shade50,
            child: Row(
              children: [
                Icon(Icons.table_rows_rounded, color: theme.colorScheme.primary, size: 16),
                const SizedBox(width: 8),
                const Text(
                  'Registros de Telemetría Pivoteados',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1E293B)),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 28,
              horizontalMargin: 16,
              headingRowHeight: 44,
              dataRowHeight: 40,
              headingRowColor: WidgetStateProperty.all(theme.colorScheme.primary.withOpacity(0.04)),
              headingTextStyle: TextStyle(
                color: theme.colorScheme.primary, 
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
              columns: headers.map((h) {
                String title = h == 'fecha_hora' ? 'FECHA Y HORA' : h.toUpperCase();
                return DataColumn(
                  label: Text(
                    title,
                    style: const TextStyle(letterSpacing: 0.5),
                  ),
                );
              }).toList(),
              rows: List.generate(dataList.length, (index) {
                final row = dataList[index];
                final isEven = index % 2 == 0;
                return DataRow(
                  color: WidgetStateProperty.all(isEven ? Colors.white : Colors.grey.shade50.withOpacity(0.5)),
                  cells: headers.map((headerKey) {
                    final val = row[headerKey];
                    if (val == null) {
                      return const DataCell(Text('-', style: TextStyle(color: Colors.grey, fontSize: 11)));
                    }
                    String displayVal = val is double ? val.toStringAsFixed(2) : val.toString();
                    bool isTime = headerKey == 'fecha_hora';
                    return DataCell(
                      Text(
                        displayVal,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: isTime ? FontWeight.w600 : FontWeight.normal,
                          color: isTime ? const Color(0xFF1E293B) : Colors.black87,
                        ),
                      ),
                    );
                  }).toList(),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// COMPONENTE: TelemetryChartWidget
// Dibuja gráficas reales y sofisticadas con CustomPainter
// ==========================================
class TelemetryChartWidget extends StatelessWidget {
  final String type; // 'line_chart' o 'histogram'
  final List<Map<String, dynamic>> dataList;

  const TelemetryChartWidget({
    super.key,
    required this.type,
    required this.dataList,
  });

  // Colores dedicados de la paleta Biobit para cada métrica
  static const Map<String, Color> metricColors = {
    'temperatura': Color(0xFFEF4444),     // Rojo vibrante
    'humedad': Color(0xFF3B82F6),         // Azul claro
    'humedad_suelo': Color(0xFF10B981),   // Esmeralda
    'luminosidad': Color(0xFFF59E0B),     // Ámbar
    'wifi_rssi': Color(0xFF8B5CF6),       // Violeta
  };

  @override
  Widget build(BuildContext context) {
    if (dataList.isEmpty) return const SizedBox();

    // 1. Extraer dinámicamente qué métricas numéricas existen en el dataset
    List<String> metrics = [];
    for (var row in dataList) {
      for (var key in row.keys) {
        if (key != 'fecha_hora' && row[key] is num) {
          if (!metrics.contains(key)) {
            metrics.add(key);
          }
        }
      }
    }

    if (metrics.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: const Text('No hay datos numéricos para graficar.', style: TextStyle(fontSize: 11)),
      );
    }

    // 2. Encontrar límites absolutos de los valores para escalar perfectamente la gráfica
    double minVal = double.infinity;
    double maxVal = -double.infinity;
    for (var row in dataList) {
      for (var m in metrics) {
        if (row.containsKey(m) && row[m] != null) {
          double val = (row[m] as num).toDouble();
          if (val < minVal) minVal = val;
          if (val > maxVal) maxVal = val;
        }
      }
    }

    // Evitar colapsos por escalas idénticas
    if (minVal == maxVal) {
      minVal = minVal - 1;
      maxVal = maxVal + 1;
    } else {
      // Dejar un margen estético superior e inferior del 10%
      double range = maxVal - minVal;
      minVal = (minVal - (range * 0.1)).clamp(0, double.infinity); // Evitar negativos a menos que aplique
      maxVal = maxVal + (range * 0.1);
    }

    // El color de tema principal para el encabezado de esta caja
    final themeColor = type == 'line_chart' ? const Color(0xFF1E3A8A) : const Color(0xFF0F766E);
    final isLineChart = type == 'line_chart';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.02),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabecera del Gráfico con icono correspondiente
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: themeColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isLineChart ? Icons.show_chart_rounded : Icons.bar_chart_rounded,
                  color: themeColor,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                isLineChart ? 'Gráfica de Tendencia (Líneas)' : 'Histograma Comparativo (Barras)',
                style: TextStyle(
                  fontWeight: FontWeight.bold, 
                  color: themeColor, 
                  fontSize: 13,
                  letterSpacing: 0.3
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // LEYENDAS: Listado de métricas dibujadas dinámicamente con sus colores reales
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: metrics.map((m) {
              final color = metricColors[m] ?? Colors.blueGrey;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withOpacity(0.2)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      m.toUpperCase().replaceAll('_', ' '),
                      style: TextStyle(
                        fontSize: 10, 
                        fontWeight: FontWeight.bold,
                        color: color.withOpacity(0.9)
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // EL CANVAS GRAFICADOR REAL
          SizedBox(
            height: 180,
            width: double.infinity,
            child: CustomPaint(
              painter: TelemetryCanvasPainter(
                type: type,
                data: List.from(dataList.reversed), // Graficar de más antiguo a más reciente (izquierda a derecha)
                metrics: metrics,
                minVal: minVal,
                maxVal: maxVal,
                colors: metricColors,
              ),
            ),
          ),
          
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Estiramiento temporal: Últimos ${dataList.length} registros del servidor',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade400, fontStyle: FontStyle.italic),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// EL MOTOR DE RENDIMIENTO GRÁFICO (CustomPainter)
// Dibuja trazados vectoriales, gradientes y rejillas de forma ultra-fluida
// ==========================================
class TelemetryCanvasPainter extends CustomPainter {
  final String type;
  final List<Map<String, dynamic>> data;
  final List<String> metrics;
  final double minVal;
  final double maxVal;
  final Map<String, Color> colors;

  TelemetryCanvasPainter({
    required this.type,
    required this.data,
    required this.metrics,
    required this.minVal,
    required this.maxVal,
    required this.colors,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.grey.shade100
      ..strokeWidth = 1;

    final axisLabelStyle = TextStyle(
      color: Colors.grey.shade400,
      fontSize: 8,
      fontWeight: FontWeight.bold,
    );

    // Definimos el marco interno útil (dejando margen para textos de ejes)
    const double paddingLeft = 32.0;
    const double paddingRight = 8.0;
    const double paddingTop = 10.0;
    const double paddingBottom = 20.0;

    final double width = size.width - paddingLeft - paddingRight;
    final double height = size.height - paddingTop - paddingBottom;

    // --- 1. DIBUJAR LÍNEAS DE REJILLA Y EJES ---
    const int verticalDivisions = 4;
    for (int i = 0; i <= verticalDivisions; i++) {
      double pct = i / verticalDivisions;
      double y = paddingTop + height * (1 - pct);
      // Dibujar línea horizontal
      canvas.drawLine(
        Offset(paddingLeft, y),
        Offset(size.width - paddingRight, y),
        gridPaint,
      );

      // Escribir etiqueta del valor numérico correspondiente en el eje Y
      double val = minVal + (maxVal - minVal) * pct;
      final textPainter = TextPainter(
        text: TextSpan(text: val.toStringAsFixed(1), style: axisLabelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(paddingLeft - textPainter.width - 6, y - textPainter.height / 2));
    }

    if (data.isEmpty) return;

    // --- 2. RENDERIZADO DEL GRÁFICO DE LÍNEAS CONÁREA CON GRADIENTE ---
    if (type == 'line_chart') {
      final double stepX = data.length > 1 ? width / (data.length - 1) : width;

      for (var m in metrics) {
        final color = colors[m] ?? Colors.blueGrey;
        final Path linePath = Path();
        final Path areaPath = Path();

        bool firstPoint = true;
        double firstX = paddingLeft;
        double lastX = paddingLeft;

        for (int i = 0; i < data.length; i++) {
          final row = data[i];
          if (row.containsKey(m) && row[m] != null) {
            double rawVal = (row[m] as num).toDouble();
            double pctY = (rawVal - minVal) / (maxVal - minVal);
            double x = paddingLeft + i * stepX;
            double y = paddingTop + height * (1 - pctY);

            if (firstPoint) {
              linePath.moveTo(x, y);
              areaPath.moveTo(x, paddingTop + height); // Punto base para cerrar área
              areaPath.lineTo(x, y);
              firstX = x;
              firstPoint = false;
            } else {
              linePath.lineTo(x, y);
              areaPath.lineTo(x, y);
            }
            lastX = x;
          }
        }

        if (!firstPoint) {
          // Cerrar el trazado del área de gradiente hacia la parte inferior
          areaPath.lineTo(lastX, paddingTop + height);
          areaPath.lineTo(firstX, paddingTop + height);
          areaPath.close();

          // Pintar gradiente estético debajo de la línea
          final Paint areaPaint = Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color.withOpacity(0.25),
                color.withOpacity(0.01),
              ],
            ).createShader(Rect.fromLTWH(paddingLeft, paddingTop, width, height));

          canvas.drawPath(areaPath, areaPaint);

          // Pintar la línea principal con suavidad y solidez
          final Paint strokePaint = Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true;

          canvas.drawPath(linePath, strokePaint);

          // Dibujar puntos pequeños en cada lectura para alta fidelidad
          final Paint pointPaint = Paint()
            ..color = color
            ..style = PaintingStyle.fill;
          final Paint pointBorderPaint = Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5;

          for (int i = 0; i < data.length; i++) {
            final row = data[i];
            if (row.containsKey(m) && row[m] != null) {
              double rawVal = (row[m] as num).toDouble();
              double pctY = (rawVal - minVal) / (maxVal - minVal);
              double x = paddingLeft + i * stepX;
              double y = paddingTop + height * (1 - pctY);

              canvas.drawCircle(Offset(x, y), 3.5, pointPaint);
              canvas.drawCircle(Offset(x, y), 3.5, pointBorderPaint);
            }
          }
        }
      }
    } 
    // --- 3. RENDERIZADO DE HISTOGRAMAS (BARRAS AGRUPADAS) ---
    else if (type == 'histogram') {
      final double groupWidth = width / data.length;
      final double barSpacing = 2.0;
      final int metricsCount = metrics.length;
      final double singleBarWidth = math.max(2.0, (groupWidth - 8) / metricsCount - barSpacing);

      for (int i = 0; i < data.length; i++) {
        final row = data[i];
        double groupStartX = paddingLeft + i * groupWidth + 4.0;

        for (int mIdx = 0; mIdx < metricsCount; mIdx++) {
          final m = metrics[mIdx];
          final color = colors[m] ?? Colors.blueGrey;

          if (row.containsKey(m) && row[m] != null) {
            double rawVal = (row[m] as num).toDouble();
            double pctY = (rawVal - minVal) / (maxVal - minVal);
            double barHeight = height * pctY;

            double barX = groupStartX + mIdx * (singleBarWidth + barSpacing);
            double barY = paddingTop + height - barHeight;

            final Paint barPaint = Paint()
              ..color = color
              ..style = PaintingStyle.fill;

            // Dibujamos barra con bordes superiores redondeados de forma fluida
            final RRect rect = RRect.fromRectAndCorners(
              Rect.fromLTWH(barX, barY, singleBarWidth, barHeight),
              topLeft: const Radius.circular(3),
              topRight: const Radius.circular(3),
            );
            canvas.drawRRect(rect, barPaint);
          }
        }
      }
    }

    // --- 4. ESCRIBIR TEXTOS CON HORARIOS EN EL EJE X ---
    if (data.isNotEmpty) {
      // Pintamos etiquetas de hora al inicio, mitad y final para no saturar visualmente
      List<int> labelIndices = [];
      if (data.length == 1) {
        labelIndices = [0];
      } else if (data.length == 2) {
        labelIndices = [0, 1];
      } else {
        labelIndices = [0, (data.length / 2).floor(), data.length - 1];
      }

      for (int index in labelIndices) {
        if (index >= 0 && index < data.length) {
          final row = data[index];
          String timeStr = '';
          if (row.containsKey('fecha_hora')) {
            // Recortamos solo la sección de la hora 'HH:MM:SS' para mantenerlo compacto
            String fullTime = row['fecha_hora'].toString();
            if (fullTime.length >= 19) {
              timeStr = fullTime.substring(11, 19);
            } else {
              timeStr = fullTime;
            }
          }

          double stepX = data.length > 1 ? width / (data.length - 1) : width;
          double x = paddingLeft + index * stepX;

          final textPainter = TextPainter(
            text: TextSpan(text: timeStr, style: axisLabelStyle),
            textDirection: TextDirection.ltr,
          )..layout();

          // Centramos el texto del eje X en su estampa respectiva
          textPainter.paint(
            canvas, 
            Offset(x - textPainter.width / 2, paddingTop + height + 6)
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant TelemetryCanvasPainter oldDelegate) {
    return oldDelegate.data != data || 
           oldDelegate.metrics != metrics || 
           oldDelegate.minVal != minVal || 
           oldDelegate.maxVal != maxVal || 
           oldDelegate.type != type;
  }
}