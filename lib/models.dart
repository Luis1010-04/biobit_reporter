// Modelo para la respuesta estructurada del LLM (Open WebUI)
class IaResponse {
  final String query;
  final String visualizationType; // text, histogram, table
  final List<String> components;

  IaResponse({
    required this.query,
    required this.visualizationType,
    required this.components,
  });

factory IaResponse.fromJson(Map<String, dynamic> json) {
    // Detectar la query sin importar si el modelo mandó 'flux_query' o 'query'
    String extractedQuery = (json['flux_query'] ?? json['query'] ?? '').toString();
    
    // Si el modelo escribió la palabra literal "null" como string, la limpiamos
    if (extractedQuery.trim().toLowerCase() == 'null') {
      extractedQuery = '';
    }

    // Detectar el comentario del asistente
    List<String> extractedComponents = [];
    if (json['assistant_comment'] != null) {
      extractedComponents.add(json['assistant_comment'].toString());
    } else if (json['components'] != null) {
      // Por si manda una lista de componentes en lugar del comentario
      if (json['components'] is List) {
        extractedComponents.add("Componentes detectados: ${(json['components'] as List).join(', ')}");
      } else {
        extractedComponents.add(json['components'].toString());
      }
    }

    return IaResponse(
      query: extractedQuery,
      visualizationType: json['visual_type'] ?? json['visualization_type'] ?? 'none',
      components: extractedComponents.isNotEmpty ? extractedComponents : ['Resultados:'],
    );
  }
}

// Modelo para los registros individuales extraídos de InfluxDB
class InfluxRecord {
  final DateTime time;
  final String field;
  final double value;
  final String dispositivo;

  InfluxRecord({
    required this.time,
    required this.field,
    required this.value,
    required this.dispositivo,
  });
}