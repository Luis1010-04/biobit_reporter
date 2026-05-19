import 'models.dart';

enum MessageSender { user, bot }

class ChatMessage {
  final String text;
  final MessageSender sender;
  
  // Datos opcionales que se adjuntan si el bot trae una gráfica o tabla
  final IaResponse? iaResponse; 
  final List<InfluxRecord>? influxData;

  ChatMessage({
    required this.text,
    required this.sender,
    this.iaResponse,
    this.influxData,
  });
}