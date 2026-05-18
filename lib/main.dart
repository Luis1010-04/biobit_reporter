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
          seedColor: const Color(0xFF1E3A8A), // Azul marino corporativo
          background: const Color(0xFFF8FAFC), // Slate-50 fondo limpio
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

  // Endpoint de OpenWebUI (Compilador de intenciones lingüísticas a JSON)
  final String openWebUiUrl = 'http://163.192.137.93:8080/api/v1/chat/completions';
  final String openWebUiKey = 'sk-86021b4ba08f4fd48e053e02c77a8b18';

  // Endpoint Directo de InfluxDB para telemetría
  final String influxUrl = 'http://163.192.137.93:8086/api/v2/query?org=ITESHU-biobit';
  final String influxToken = 'vyUOGMMbBkkz__6Z8c4UMVf-fU3FibiCoaxQC6WSbiFt-b_wZOColfR_hD410V5UBCm8rDCYaRWrlDEIhw7yiQ==';

  /// LÓGICA DE NEGOCIO: Consulta de telemetría a InfluxDB
  Future<List<Map<String, dynamic>>?> _executeFluxOnInflux(String fluxQuery) async {
    final dio = Dio();
    try {
      print('🛰️ Consultando base de datos con consulta Flux de la IA...');
      
      // OPTIMIZACIÓN DE RANGO: Elevamos el límite de 100 a 500 registros para capturar ventanas temporales más amplias (ej: 2 a 6 horas)
      String optimizedQuery = fluxQuery;
      if (fluxQuery.contains('limit(n:')) {
        optimizedQuery = fluxQuery.replaceAll(RegExp(r'limit\(n:\s*\d+\)'), 'limit(n: 500)');
      } else {
        // Si la IA olvidó poner un limitador, forzamos el límite máximo seguro de 500
        optimizedQuery = '$fluxQuery\n  |> limit(n: 500)';
      }

      final response = await dio.post(
        influxUrl,
        data: optimizedQuery,
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
      print('❌ Error al ejecutar consulta directa en InfluxDB: $e');
    }
    return null;
  }

  /// ALGORITMO: Transposición Matricial / Pivoteo de series temporales
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
          DateTime mexicoDateTime = utcDateTime.subtract(const Duration(hours: 6)); // Ajuste oficial hora de México
          String formattedTime = "${mexicoDateTime.year}-${mexicoDateTime.month.toString().padLeft(2, '0')}-${mexicoDateTime.day.toString().padLeft(2, '0')} ${mexicoDateTime.hour.toString().padLeft(2, '0')}:${mexicoDateTime.minute.toString().padLeft(2, '0')}:${mexicoDateTime.second.toString().padLeft(2, '0')}";

          // columns[7] es _field (sensor), columns[6] es _value (magnitud)
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
      
      List<Map<String, dynamic>> apiMessages = [];
      for (var m in _messages) {
        if (m.containsKey('content') && m['content'] != null) {
          apiMessages.add({'role': m['role'], 'content': m['content']});
        }
      }

      // 1. LLAMADA AL COMPILADOR DE CONTEXTO EN OPENWEBUI
      final response = await dio.post(
        openWebUiUrl,
        data: {
          'model': 'analista-influx',
          'messages': apiMessages,
          'temperature': 0.0,
          'tool_ids': [],
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $openWebUiKey',
            'Content-Type': 'application/json',
          },
        ),
      );

      final String aiRawResponse = response.data['choices'][0]['message']['content'].toString().trim();
      print('📥 JSON Compilado de OpenWebUI:\n$aiRawResponse');

      // 2. PARSEO DE PARÁMETROS DE INTENCIONES
      Map<String, dynamic> parsedAiJson;
      try {
        parsedAiJson = jsonDecode(aiRawResponse);
      } catch (e) {
        final jsonRegex = RegExp(r'```json([\s\S]*?)```');
        final match = jsonRegex.firstMatch(aiRawResponse);
        if (match != null) {
          parsedAiJson = jsonDecode(match.group(1)!.trim());
        } else {
          throw Exception("Fallo en estructura JSON de respuesta.");
        }
      }

      List<Map<String, dynamic>>? databaseRecords;
      
      // 3. CAPA DE INTERCEPCIÓN DE ACCIONES
      if (parsedAiJson['action'] == 'query_db' && parsedAiJson['flux_query'] != null) {
        databaseRecords = await _executeFluxOnInflux(parsedAiJson['flux_query']);
      }

      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': parsedAiJson['assistant_comment'] ?? 'Consulta procesada de manera correcta.',
          'visual_type': parsedAiJson['visual_type'] ?? 'none',
          'telemetry_data': databaseRecords,
        });
      });

    } catch (e) {
      setState(() {
        _messages.add({
          'role': 'assistant',
          'content': '⚠️ No se pudo procesar la instrucción analítica con el compilador lingüístico.',
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
                  'Dashboard Analítico Interactivo',
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
                      // Globo de Chat Estilizado
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
                      
                      // CONTENEDOR DE COMPONENTES VISUALES AVANZADOS E INTERACTIVOS
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

  /// Construye los widgets dinámicos mapeando a clases que soportan paginación e interacción
  Widget _renderUiComponent(String type, List<Map<String, dynamic>> data) {
    if (type == 'data_table') {
      return PaginatedTelemetryTable(dataList: data);
    } else if (type == 'line_chart' || type == 'histogram') {
      return InteractiveTelemetryChart(type: type, dataList: data);
    }
    return PaginatedTelemetryTable(dataList: data);
  }
}

// ==========================================
// NUEVO COMPONENTE: PaginatedTelemetryTable
// Tabla con navegación de páginas y selector dinámico de filas (Estilo DataTable Web)
// ==========================================
class PaginatedTelemetryTable extends StatefulWidget {
  final List<Map<String, dynamic>> dataList;

  const PaginatedTelemetryTable({super.key, required this.dataList});

  @override
  State<PaginatedTelemetryTable> createState() => _PaginatedTelemetryTableState();
}

class _PaginatedTelemetryTableState extends State<PaginatedTelemetryTable> {
  int _currentPage = 0;
  int _rowsPerPage = 10; // Valor por defecto ajustable dinámicamente

  // Opciones estándar para el selector de filas por página
  final List<int> _rowsPerPageOptions = [10, 20, 30, 50, 100];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    List<String> headers = ['fecha_hora'];
    for (var row in widget.dataList) {
      for (var key in row.keys) {
        if (!headers.contains(key)) headers.add(key);
      }
    }

    // Algoritmo de rebanado dinámico para paginar en memoria según la elección del usuario
    final int totalRecords = widget.dataList.length;
    final int maxPages = (totalRecords / _rowsPerPage).ceil();
    
    // Validamos que el cambio dinámico de tamaño de página no deje la página actual fuera de rango
    if (_currentPage >= maxPages && maxPages > 0) {
      _currentPage = maxPages - 1;
    }

    final int startIdx = _currentPage * _rowsPerPage;
    final int endIdx = (startIdx + _rowsPerPage).clamp(0, totalRecords);
    
    final List<Map<String, dynamic>> pagedData = widget.dataList.sublist(startIdx, endIdx);

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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // CABECERA ESTILO DATATABLE: Título + Selector interactivo de filas
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.grey.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.table_rows_rounded, color: theme.colorScheme.primary, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'Datos (${widget.dataList.length} registros)',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1E293B)),
                    ),
                  ],
                ),
                
                // Selector interactivo de filas (DropdownButton de Material 3)
                Row(
                  children: [
                    Text(
                      'Mostrar: ',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.bold),
                    ),
                    Container(
                      height: 28,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<int>(
                          value: _rowsPerPage,
                          icon: const Icon(Icons.arrow_drop_down_rounded, size: 18, color: Colors.grey),
                          style: TextStyle(fontSize: 11, color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
                          onChanged: (int? newValue) {
                            if (newValue != null) {
                              setState(() {
                                _rowsPerPage = newValue;
                                _currentPage = 0; // Regresamos a la primera página para evitar desfases de índices
                              });
                            }
                          },
                          items: _rowsPerPageOptions.map<DropdownMenuItem<int>>((int value) {
                            return DropdownMenuItem<int>(
                              value: value,
                              child: Text('$value'),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          
          // Tabla de Datos Deslizable Horizontalmente
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              horizontalMargin: 16,
              headingRowHeight: 40,
              dataRowHeight: 38,
              headingRowColor: WidgetStateProperty.all(theme.colorScheme.primary.withOpacity(0.04)),
              headingTextStyle: TextStyle(
                color: theme.colorScheme.primary, 
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
              columns: headers.map((h) {
                String title = h == 'fecha_hora' ? 'FECHA Y HORA' : h.toUpperCase();
                return DataColumn(label: Text(title));
              }).toList(),
              rows: List.generate(pagedData.length, (index) {
                final row = pagedData[index];
                final isEven = index % 2 == 0;
                return DataRow(
                  color: WidgetStateProperty.all(isEven ? Colors.white : Colors.grey.shade50.withOpacity(0.3)),
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
          
          // CONTROLES DE PAGINACIÓN INTERACTIVA
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Mostrando ${totalRecords == 0 ? 0 : startIdx + 1}-${endIdx} de $totalRecords',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left_rounded, size: 20),
                      onPressed: _currentPage > 0 
                          ? () => setState(() => _currentPage--) 
                          : null,
                    ),
                    Text(
                      '${totalRecords == 0 ? 0 : _currentPage + 1} / ${maxPages == 0 ? 1 : maxPages}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right_rounded, size: 20),
                      onPressed: _currentPage < maxPages - 1 
                          ? () => setState(() => _currentPage++) 
                          : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// NUEVO COMPONENTE: InteractiveTelemetryChart
// Gráfica de CustomPainter con soporte de gestos (Hover/Drag) y Paginación Temporal
// ==========================================
class InteractiveTelemetryChart extends StatefulWidget {
  final String type; // 'line_chart' o 'histogram'
  final List<Map<String, dynamic>> dataList;

  const InteractiveTelemetryChart({
    super.key,
    required this.type,
    required this.dataList,
  });

  @override
  State<InteractiveTelemetryChart> createState() => _InteractiveTelemetryChartState();
}

class _InteractiveTelemetryChartState extends State<InteractiveTelemetryChart> {
  int _currentPage = 0;
  final int _itemsPerPage = 12; // Cantidad ideal de puntos para no saturar horizontalmente
  
  // Estado para la interacción gestual en el Canvas
  int? _hoveredIndex;
  Offset? _hoverPosition;

  static const Map<String, Color> metricColors = {
    'temperatura': Color(0xFFEF4444),     // Rojo
    'humedad': Color(0xFF3B82F6),         // Azul
    'humedad_suelo': Color(0xFF10B981),   // Verde
    'luminosidad': Color(0xFFF59E0B),     // Ámbar
    'wifi_rssi': Color(0xFF8B5CF6),       // Violeta
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLineChart = widget.type == 'line_chart';
    final themeColor = isLineChart ? const Color(0xFF1E3A8A) : const Color(0xFF0F766E);

    if (widget.dataList.isEmpty) return const SizedBox();

    // 1. Extraer métricas numéricas dinámicas
    List<String> metrics = [];
    for (var row in widget.dataList) {
      for (var key in row.keys) {
        if (key != 'fecha_hora' && row[key] is num) {
          if (!metrics.contains(key)) metrics.add(key);
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

    // 2. Control de Paginación Temporal de los Datos
    final int totalRecords = widget.dataList.length;
    final int maxPages = (totalRecords / _itemsPerPage).ceil();
    final int startIdx = _currentPage * _itemsPerPage;
    final int endIdx = (startIdx + _itemsPerPage).clamp(0, totalRecords);

    // Cortamos la página seleccionada
    final List<Map<String, dynamic>> pageRecords = widget.dataList.sublist(startIdx, endIdx);
    
    // Invertimos cronológicamente para pintar de izquierda a derecha (antiguo a reciente)
    final List<Map<String, dynamic>> renderRecords = List.from(pageRecords.reversed);

    // 3. Encontrar límites dinámicos para el escalado
    double minVal = double.infinity;
    double maxVal = -double.infinity;
    for (var row in renderRecords) {
      for (var m in metrics) {
        if (row.containsKey(m) && row[m] != null) {
          double val = (row[m] as num).toDouble();
          if (val < minVal) minVal = val;
          if (val > maxVal) maxVal = val;
        }
      }
    }

    if (minVal == maxVal) {
      minVal = minVal - 1;
      maxVal = maxVal + 1;
    } else {
      double range = maxVal - minVal;
      minVal = (minVal - (range * 0.1)).clamp(0, double.infinity);
      maxVal = maxVal + (range * 0.1);
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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cabecera interactiva
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
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
                    isLineChart ? 'Tendencias Interactivas' : 'Histograma Ajustable',
                    style: TextStyle(fontWeight: FontWeight.bold, color: themeColor, fontSize: 13),
                  ),
                ],
              ),
              
              // Pequeño indicador del estado interactivo
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.touch_app_rounded, size: 10, color: Colors.grey),
                    SizedBox(width: 4),
                    Text('Desliza/Toca', style: TextStyle(fontSize: 9, color: Colors.grey, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // LEYENDAS COLORIDAS
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: metrics.map((m) {
              final color = metricColors[m] ?? Colors.blueGrey;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: color.withOpacity(0.15)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                    const SizedBox(width: 4),
                    Text(
                      m.toUpperCase().replaceAll('_', ' '),
                      style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color.withOpacity(0.85)),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // CANVAS + CONTROL DE GESTOS EN STACK
          LayoutBuilder(
            builder: (context, constraints) {
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  GestureDetector(
                    onPanStart: (details) => _handleGesture(details.localPosition, constraints.maxWidth, renderRecords.length),
                    onPanUpdate: (details) => _handleGesture(details.localPosition, constraints.maxWidth, renderRecords.length),
                    onPanEnd: (_) => setState(() {
                      _hoveredIndex = null;
                      _hoverPosition = null;
                    }),
                    onTapDown: (details) => _handleGesture(details.localPosition, constraints.maxWidth, renderRecords.length),
                    onTapUp: (_) => setState(() {
                      _hoveredIndex = null;
                      _hoverPosition = null;
                    }),
                    child: SizedBox(
                      height: 180,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: TelemetryCanvasPainter(
                          type: widget.type,
                          data: renderRecords,
                          metrics: metrics,
                          minVal: minVal,
                          maxVal: maxVal,
                          colors: metricColors,
                          hoveredIndex: _hoveredIndex,
                        ),
                      ),
                    ),
                  ),

                  // PANEL FLOTANTE DE INTERACCIÓN (TOOLTIP DINÁMICO)
                  if (_hoveredIndex != null && _hoveredIndex! < renderRecords.length && _hoverPosition != null) ...[
                    _buildInteractiveTooltip(renderRecords[_hoveredIndex!], metrics, constraints.maxWidth),
                  ],
                ],
              );
            },
          ),
          
          const SizedBox(height: 12),

          // CONTROLES DE NAVEGACIÓN DE HISTORIAL DE GRÁFICAS
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                icon: const Icon(Icons.arrow_back_rounded, size: 16),
                label: const Text('Más Antiguos', style: TextStyle(fontSize: 11)),
                onPressed: _currentPage < maxPages - 1 
                    ? () => setState(() {
                          _currentPage++;
                          _hoveredIndex = null;
                        }) 
                    : null,
              ),
              Text(
                'Ventana ${_currentPage + 1} de $maxPages',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500, fontWeight: FontWeight.bold),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: const Text('Más Recientes', style: TextStyle(fontSize: 11)),
                onPressed: _currentPage > 0 
                    ? () => setState(() {
                          _currentPage--;
                          _hoveredIndex = null;
                        }) 
                    : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Procesa las coordenadas del gesto para ubicar la lectura de sensores más cercana
  void _handleGesture(Offset localPos, double totalWidth, int count) {
    if (count <= 1) return;

    const double paddingLeft = 32.0;
    const double paddingRight = 8.0;
    final double usableWidth = totalWidth - paddingLeft - paddingRight;
    final double relativeX = localPos.dx - paddingLeft;

    if (relativeX >= 0 && relativeX <= usableWidth) {
      final double stepX = usableWidth / (count - 1);
      final int index = (relativeX / stepX).round().clamp(0, count - 1);
      
      setState(() {
        _hoveredIndex = index;
        _hoverPosition = localPos;
      });
    }
  }

  /// Construye un Tooltip flotante estilizado Material 3 que cambia de lado automáticamente para no salirse de los límites
  Widget _buildInteractiveTooltip(Map<String, dynamic> record, List<String> metrics, double chartWidth) {
    final theme = Theme.of(context);
    final isLeftHalf = _hoverPosition!.dx < (chartWidth / 2);
    
    // Posiciona el tooltip a la derecha o izquierda del dedo/puntero según corresponda
    final double leftOffset = isLeftHalf ? _hoverPosition!.dx + 16 : _hoverPosition!.dx - 176;
    final String timeStr = record['fecha_hora'].toString().substring(11, 19);

    return Positioned(
      left: leftOffset,
      top: 5,
      child: Container(
        width: 160,
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withOpacity(0.95), // Fondo pizarra oscuro ejecutivo (slate-900)
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 8,
              offset: const Offset(0, 4),
            )
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(Icons.schedule, color: Colors.blue.shade300, size: 11),
                Text(
                  timeStr,
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const Divider(color: Colors.white12, height: 8),
            ...metrics.map((m) {
              final color = metricColors[m] ?? Colors.grey;
              final val = record[m];
              final displayVal = val != null ? (val as num).toStringAsFixed(1) : '-';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(width: 5, height: 5, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                        const SizedBox(width: 4),
                        Text(
                          m.replaceAll('_', ' '),
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 8, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    Text(
                      displayVal,
                      style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              );
            }).toList(),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// EL MOTOR DE RENDIMIENTO GRÁFICO (CustomPainter)
// Renderiza trazados, cuadrículas y las guías interactivas del Hover
// ==========================================
class TelemetryCanvasPainter extends CustomPainter {
  final String type;
  final List<Map<String, dynamic>> data;
  final List<String> metrics;
  final double minVal;
  final double maxVal;
  final Map<String, Color> colors;
  final int? hoveredIndex; // Índice activo interactivo

  TelemetryCanvasPainter({
    required this.type,
    required this.data,
    required this.metrics,
    required this.minVal,
    required this.maxVal,
    required this.colors,
    this.hoveredIndex,
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
      canvas.drawLine(
        Offset(paddingLeft, y),
        Offset(size.width - paddingRight, y),
        gridPaint,
      );

      double val = minVal + (maxVal - minVal) * pct;
      final textPainter = TextPainter(
        text: TextSpan(text: val.toStringAsFixed(1), style: axisLabelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(paddingLeft - textPainter.width - 6, y - textPainter.height / 2));
    }

    if (data.isEmpty) return;

    // --- 2. DIBUJAR LÍNEAS DE GUÍA INTERACTIVA (VERTICAL HOVER) ---
    final double stepX = data.length > 1 ? width / (data.length - 1) : width;
    if (hoveredIndex != null && hoveredIndex! < data.length) {
      final double hoverX = paddingLeft + hoveredIndex! * stepX;
      final Paint hoverLinePaint = Paint()
        ..color = const Color(0xFF64748B).withOpacity(0.4) // Slate-500 traslúcido
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      
      // Dibujar línea de guía vertical de polo a polo
      canvas.drawLine(
        Offset(hoverX, paddingTop),
        Offset(hoverX, paddingTop + height),
        hoverLinePaint,
      );
    }

    // --- 3. RENDERIZADO DEL GRÁFICO DE LÍNEAS ---
    if (type == 'line_chart') {
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
              areaPath.moveTo(x, paddingTop + height);
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
          areaPath.lineTo(lastX, paddingTop + height);
          areaPath.lineTo(firstX, paddingTop + height);
          areaPath.close();

          // Sombreado elegante de gradiente degradado
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

          final Paint strokePaint = Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5
            ..strokeCap = StrokeCap.round
            ..isAntiAlias = true;

          canvas.drawPath(linePath, strokePaint);

          // Dibujar círculos en cada vértice
          final Paint pointPaint = Paint()..color = color;
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

              // Resaltar visualmente si el punto está siendo interactuado (hovered)
              bool isHovered = hoveredIndex == i;
              double radius = isHovered ? 6.0 : 3.5;
              
              if (isHovered) {
                // Dibujar un halo de brillo interactivo
                canvas.drawCircle(Offset(x, y), 9.0, Paint()..color = color.withOpacity(0.2));
              }

              canvas.drawCircle(Offset(x, y), radius, pointPaint);
              canvas.drawCircle(Offset(x, y), radius, pointBorderPaint);
            }
          }
        }
      }
    } 
    // --- 4. RENDERIZADO DE HISTOGRAMAS (BARRAS AGRUPADAS) ---
    else if (type == 'histogram') {
      final double groupWidth = width / data.length;
      final double barSpacing = 1.5;
      final int metricsCount = metrics.length;
      final double singleBarWidth = math.max(2.0, (groupWidth - 8) / metricsCount - barSpacing);

      for (int i = 0; i < data.length; i++) {
        final row = data[i];
        double groupStartX = paddingLeft + i * groupWidth + 4.0;
        bool isGroupHovered = hoveredIndex == i;

        for (int mIdx = 0; mIdx < metricsCount; mIdx++) {
          final m = metrics[mIdx];
          final color = colors[m] ?? Colors.blueGrey;

          if (row.containsKey(m) && row[m] != null) {
            double rawVal = (row[m] as num).toDouble();
            double pctY = (rawVal - minVal) / (maxVal - minVal);
            double barHeight = height * pctY;

            double barX = groupStartX + mIdx * (singleBarWidth + barSpacing);
            double barY = paddingTop + height - barHeight;

            // Opacidad inteligente según si el elemento está activo o no bajo el cursor
            Color renderColor = isGroupHovered 
                ? color 
                : (hoveredIndex == null ? color : color.withOpacity(0.4));

            final Paint barPaint = Paint()
              ..color = renderColor
              ..style = PaintingStyle.fill;

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

    // --- 5. LÍNEAS DE EJE X CON HORAS ---
    if (data.isNotEmpty) {
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
            String fullTime = row['fecha_hora'].toString();
            if (fullTime.length >= 19) {
              timeStr = fullTime.substring(11, 19);
            } else {
              timeStr = fullTime;
            }
          }

          double x = paddingLeft + index * stepX;

          final textPainter = TextPainter(
            text: TextSpan(text: timeStr, style: axisLabelStyle),
            textDirection: TextDirection.ltr,
          )..layout();

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
           oldDelegate.hoveredIndex != hoveredIndex ||
           oldDelegate.type != type;
  }
}