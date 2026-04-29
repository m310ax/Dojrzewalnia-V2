class Device {
  const Device({required this.id});

  final String id;

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(id: json['id']?.toString() ?? '');
  }
}