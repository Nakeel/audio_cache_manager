// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'hls_segment_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class HlsSegmentEntryAdapter extends TypeAdapter<HlsSegmentEntry> {
  @override
  final int typeId = 179;

  @override
  HlsSegmentEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return HlsSegmentEntry(
      originalUrl: fields[0] as String,
      localRelativePath: fields[1] as String,
      downloadedBytes: fields[2] as int,
      totalBytes: fields[3] as int,
      isComplete: fields[4] as bool,
      dataHash: fields[5] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, HlsSegmentEntry obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.originalUrl)
      ..writeByte(1)
      ..write(obj.localRelativePath)
      ..writeByte(2)
      ..write(obj.downloadedBytes)
      ..writeByte(3)
      ..write(obj.totalBytes)
      ..writeByte(4)
      ..write(obj.isComplete)
      ..writeByte(5)
      ..write(obj.dataHash);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HlsSegmentEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
