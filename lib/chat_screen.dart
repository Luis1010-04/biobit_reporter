import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';
import 'models.dart';
import 'chat_message.dart';
import 'influx_service.dart';

// 1. CLASE AUXILIAR: Representa cada renglón horizontal en la matriz de visualización
class RenglonMatriz {
  final String horaMuestra;
  final Map<String, String> lecturas; // Clave: Nombre del componente, Valor: Medición

  RenglonMatriz({required this.horaMuestra, required this.lecturas});
}

// 2. FUNCIÓN UTILITARIA: Pivota los registros planos a formato matricial con la fecha a la izquierda
Map<String, dynamic> transformarAMatriz(List<InfluxRecord> registrosPlanos) {
  if (registrosPlanos.isEmpty) return {'cabeceras': <String>[], 'filas': <RenglonMatriz>[]};

  // Extraemos el listado de componentes únicos que vinieron en la telemetría para las columnas
  final encabezados = registrosPlanos.map((r) => r.field).toSet().toList();

  // Agrupamos temporalmente los campos que comparten el mismo timestamp exacto
  final Map<String, Map<String, String>> mapaAgrupado = {};

  for (var registro in registrosPlanos) {
    // Formato de fecha corto e intuitivo para la columna izquierda (Ej: 19/05 14:55)
    final horaKey = "${registro.time.day.toString().padLeft(2, '0')}/${registro.time.month.toString().padLeft(2, '0')} ${registro.time.hour.toString().padLeft(2, '0')}:${registro.time.minute.toString().padLeft(2, '0')}";

    if (!mapaAgrupado.containsKey(horaKey)) {
      mapaAgrupado[horaKey] = {};
    }
    // Guardamos la medición formateada a un decimal
    mapaAgrupado[horaKey]![registro.field] = registro.value.toStringAsFixed(1);
  }

  // Ordenamos cronológicamente de forma descendente (los más recientes arriba)
  final horasOrdenadas = mapaAgrupado.keys.toList()..sort((a, b) => b.compareTo(a));
  final List<RenglonMatriz> filasFinales = horasOrdenadas.map((hora) {
    return RenglonMatriz(horaMuestra: hora, lecturas: mapaAgrupado[hora]!);
  }).toList();

  return {
    'cabeceras': encabezados,
    'filas': filasFinales,
  };
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final List<ChatMessage> _messages = [];
  final InfluxService _influxService = InfluxService();
  bool _isLoading = false;

  void _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    _controller.clear();
    setState(() {
      _messages.add(ChatMessage(text: text, sender: MessageSender.user));
      _isLoading = true;
    });

    try {
      final iaResponse = await _influxService.translateNaturalLanguage(text);
      List<InfluxRecord>? influxData;

      if (iaResponse.query.trim().isNotEmpty) {
        influxData = await _influxService.queryInfluxDB(iaResponse.query);
      } else {
        print('💡 Info: No se ejecutó Query en InfluxDB porque la IA determinó que es un chat conversacional.');
      }

      setState(() {
        _messages.add(ChatMessage(
          text: iaResponse.components.isNotEmpty 
              ? iaResponse.components.join(' ') 
              : 'Resultados de la consulta:',
          sender: MessageSender.bot,
          iaResponse: iaResponse,
          influxData: influxData,
        ));
      });
    } catch (e) {
      setState(() {
        _messages.add(ChatMessage(
          text: 'Lo siento, ocurrió un error al procesar tu solicitud: $e',
          sender: MessageSender.bot,
        ));
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Biobit Reporter IA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: Colors.teal,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageBubble(msg);
              },
            ),
          ),
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8.0),
              child: CircularProgressIndicator(color: Colors.teal),
            ),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isUser = msg.sender == MessageSender.user;
    return Column(
      crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.symmetric(vertical: 5),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isUser ? Colors.teal[100] : Colors.grey[200],
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            msg.text,
            style: const TextStyle(fontSize: 16, color: Colors.black87),
          ),
        ),
        if (!isUser && msg.influxData != null && msg.iaResponse != null)
          _renderVisualization(msg.iaResponse!, msg.influxData!),
      ],
    );
  }

  Widget _renderVisualization(IaResponse ia, List<InfluxRecord> data) {
    if (data.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: Text('No hay registros disponibles en ese rango de tiempo.', 
          style: TextStyle(color: Colors.red, fontStyle: FontStyle.italic)),
      );
    }

    switch (ia.visualizationType) {
      case 'table':
        return _buildTable(data); // Renderiza la nueva tabla estructurada
      case 'histogram':
        return _buildHistogram(data);
      case 'text':
      default:
        return _buildTextData(data);
    }
  }

  Widget _buildTextData(List<InfluxRecord> data) {
    final format = DateFormat('dd/MM/yyyy hh:mm a');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: data.map((item) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Text(
                '• Componente: ${item.field} | Valor: ${item.value.toStringAsFixed(2)} | Fecha: ${format.format(item.time)}',
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // 3. SECCIÓN RE-ESTRUCTURADA: Renderiza la tabla matricial con scroll bidireccional
  Widget _buildTable(List<InfluxRecord> data) {
    final datosEstructurados = transformarAMatriz(data);
    final List<String> cabecerasComponentes = List<String>.from(datosEstructurados['cabeceras']);
    final List<RenglonMatriz> filasTabla = List<RenglonMatriz>.from(datosEstructurados['filas']);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      constraints: const BoxConstraints(maxHeight: 320), // Controla la altura máxima para no romper el flujo del chat
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1), // Corregido: Soluciona el error de compilación de Colors.black10
            blurRadius: 4,
          )
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical, // Scroll vertical para navegar las distintas horas
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal, // Scroll horizontal para ver todos los componentes
            child: DataTable(
              columnSpacing: 28,
              headingRowColor: WidgetStateProperty.all(Colors.teal.shade700), // Encabezado elegante estilo Biobit
              columns: [
                // Columna base izquierda obligatoria para las marcas de tiempo
                const DataColumn(
                  label: Text('Fecha y hora', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                // Columnas dinámicas generadas a partir de los componentes mapeados
                ...cabecerasComponentes.map((componente) => DataColumn(
                  label: Text(componente, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                )),
              ],
              rows: filasTabla.map((fila) {
                return DataRow(
                  cells: [
                    // Celda de fecha y hora
                    DataCell(Text(fila.horaMuestra, style: const TextStyle(fontWeight: FontWeight.w500))),
                    // Celdas dinámicas que buscan el valor del componente para esta hora específica
                    ...cabecerasComponentes.map((componente) {
                      final valor = fila.lecturas[componente] ?? '---'; // Muestra guiones si no hay registro
                      return DataCell(Text(valor));
                    }),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHistogram(List<InfluxRecord> data) {
    List<BarChartGroupData> barGroups = [];
    for (int i = 0; i < data.length; i++) {
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: data[i].value,
              color: Colors.teal,
              width: 16,
              borderRadius: BorderRadius.circular(4),
            )
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      height: 220,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 4)]
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: (data.length * 50).clamp(320, 3000).toDouble(),
          child: BarChart(
            BarChartData(
              alignment: BarChartAlignment.spaceAround,
              maxY: data.map((e) => e.value).reduce((a, b) => a > b ? a : b) * 1.2,
              barGroups: barGroups,
              gridData: const FlGridData(show: false),
              titlesData: FlTitlesData(
                leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40)),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    getTitlesWidget: (value, meta) {
                      int index = value.toInt();
                      if (index >= 0 && index < data.length) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4.0),
                          child: Text(
                            DateFormat('dd/MM HH:mm').format(data[index].time),
                            style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold),
                          ),
                        );
                      }
                      return const Text('');
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputArea() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.grey.shade300, blurRadius: 4, offset: const Offset(0, -2))]
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              decoration: const InputDecoration(
                hintText: 'Pregúntale al analista sobre los nodos...',
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _sendMessage(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.send, color: Colors.teal),
            onPressed: _sendMessage,
          ),
        ],
      ),
    );
  }
}