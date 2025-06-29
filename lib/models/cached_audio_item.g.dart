// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'cached_audio_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class CachedAudioItemAdapter extends TypeAdapter<CachedAudioItem> {
  @override
  final int typeId = 0;

  @override
  CachedAudioItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return CachedAudioItem(
      trackId: fields[0] as String,
      originalUrl: fields[1] as String,
      localPath: fields[2] as String,
      downloadedAt: fields[3] as DateTime,
      lastAccessedAt: fields[4] as DateTime,
      fileSize: fields[5] as int,
      isEncrypted: fields[6] as bool,
      isHls: fields[7] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, CachedAudioItem obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.trackId)
      ..writeByte(1)
      ..write(obj.originalUrl)
      ..writeByte(2)
      ..write(obj.localPath)
      ..writeByte(3)
      ..write(obj.downloadedAt)
      ..writeByte(4)
      ..write(obj.lastAccessedAt)
      ..writeByte(5)
      ..write(obj.fileSize)
      ..writeByte(6)
      ..write(obj.isEncrypted)
      ..writeByte(7)
      ..write(obj.isHls);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedAudioItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
