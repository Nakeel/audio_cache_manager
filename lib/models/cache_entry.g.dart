// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cache_entry.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CacheEntryAdapter extends TypeAdapter<CacheEntry> {
  @override
  final int typeId = 178;

  @override
  CacheEntry read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CacheEntry(
      trackId: fields[0] as String,
      originalUrl: fields[1] as String,
      filePath: fields[2] as String,
      timestamp: fields[3] as DateTime,
      fileSize: fields[4] as int,
      isEncrypted: fields[5] as bool,
      etag: fields[6] as String,
      lastModified: fields[7] as String,
      contentType: fields[8] as String,
      proxyUrl: fields[9] as String,
      isHls: fields[10] as bool,
      hlsLocalPath: fields[11] as String?,
      hlsSegments: (fields[12] as List?)?.cast<HlsSegmentEntry>(),
      dataHash: fields[13] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, CacheEntry obj) {
    writer
      ..writeByte(14)
      ..writeByte(0)
      ..write(obj.trackId)
      ..writeByte(1)
      ..write(obj.originalUrl)
      ..writeByte(2)
      ..write(obj.filePath)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(4)
      ..write(obj.fileSize)
      ..writeByte(5)
      ..write(obj.isEncrypted)
      ..writeByte(6)
      ..write(obj.etag)
      ..writeByte(7)
      ..write(obj.lastModified)
      ..writeByte(8)
      ..write(obj.contentType)
      ..writeByte(9)
      ..write(obj.proxyUrl)
      ..writeByte(10)
      ..write(obj.isHls)
      ..writeByte(11)
      ..write(obj.hlsLocalPath)
      ..writeByte(12)
      ..write(obj.hlsSegments)
      ..writeByte(13)
      ..write(obj.dataHash);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CacheEntryAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
