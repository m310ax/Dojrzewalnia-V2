class Device {
  const Device({required this.id, required this.name});

  final String id;
  final String name;

  factory Device.fromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final name = json['name']?.toString();

    return Device(id: id, name: (name == null || name.isEmpty) ? id : name);
  }
}