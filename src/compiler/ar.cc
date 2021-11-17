// Copyright (C) 2020 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

#include <errno.h>
#include <stdio.h>

#include "ar.h"
#include "../utils.h"

namespace toit {
namespace ar {

static const char* const AR_HEADER = "!<arch>\x0A";
static const int AR_HEADER_SIZE = strlen(AR_HEADER);

static constexpr const char* const FILE_HEADER_ENDING_CHARS = "\x60\x0A";
static const int FILE_NAME_OFFSET = 0;
static const int FILE_TIMESTAMP_OFFSET = 16;
static const int FILE_OWNER_ID_OFFSET = 28;
static const int FILE_GROUP_ID_OFFSET = 34;
static const int FILE_MODE_OFFSET = 40;
static const int FILE_BYTE_SIZE_OFFSET = 48;
static const int FILE_ENDING_CHARS_OFFSET = 58;
static const int FILE_HEADER_SIZE = 60;

static const char PADDING_CHAR = '\x0A';
static const char* PADDING_STRING = "\x0A";

static const int FILE_NAME_SIZE = FILE_TIMESTAMP_OFFSET - FILE_NAME_OFFSET;
static const int FILE_TIMESTAMP_SIZE = FILE_OWNER_ID_OFFSET - FILE_TIMESTAMP_OFFSET;
static const int FILE_OWNER_ID_SIZE = FILE_GROUP_ID_OFFSET - FILE_OWNER_ID_OFFSET;
static const int FILE_GROUP_ID_SIZE = FILE_MODE_OFFSET - FILE_GROUP_ID_OFFSET;
static const int FILE_MODE_SIZE = FILE_BYTE_SIZE_OFFSET - FILE_MODE_OFFSET;
static const int FILE_BYTE_SIZE_SIZE = FILE_ENDING_CHARS_OFFSET - FILE_BYTE_SIZE_OFFSET;
static const int FILE_ENDING_CHARS_SIZE = FILE_HEADER_SIZE - FILE_ENDING_CHARS_OFFSET;

static void write_string(uint8* buffer, const char* str, int length) {
  // The string is truncated if it is too long.
  for (int i = 0; i < length; i++) {
    char c = *str;
    if (c == '\0') {
      // Pad with spaces.
      c = ' ';
    } else {
      str++;
    }
    buffer[i] = c;
  }
}

static void write_number(uint8* buffer, int number, int length, int base) {
  // The number is trimmed if it doesn't fit.
  // For simplicity, we write the number right to left, and then shift the
  // computed values.
  int i = length - 1;
  for (; i >= 0; i--) {
    buffer[i] = '0' + number % base;
    number = number / base;
    if (number == 0) break;
  }
  // 'i' is the last entry where we wrote a significant digit.
  int nb_digits = length - i;
  int offset = i;
  for (int j = 0; j < nb_digits; j++) {
    buffer[j] = buffer[j + offset];
  }
  for (int j = nb_digits; j < length; j++) {
    buffer[j] = ' ';
  }
}

static void write_decimal(uint8* buffer, int number, int length) {
  write_number(buffer, number, length, 10);
}

static void write_octal(uint8* buffer, int number, int length) {
  write_number(buffer, number, length, 8);
}

static void write_ar_file_header(uint8* buffer, const File& file) {
  // Theset values are the same as for the "D" flag ("Operate
  // in deterministic mode") of 'ar'.
  int modification_timestamp = 0;
  int owner_id = 0;
  int group_id = 0;
  int mode = 0644;  // Octal number

  // The file name is truncated if it is too long.
  write_string(&buffer[FILE_NAME_OFFSET],
               file.name(),
               FILE_NAME_SIZE);
  write_decimal(&buffer[FILE_TIMESTAMP_OFFSET],
                modification_timestamp,
                FILE_TIMESTAMP_SIZE);
  write_decimal(&buffer[FILE_OWNER_ID_OFFSET],
                owner_id,
                FILE_OWNER_ID_SIZE);
  write_decimal(&buffer[FILE_GROUP_ID_OFFSET],
                group_id,
                FILE_GROUP_ID_SIZE);
  write_octal(&buffer[FILE_MODE_OFFSET],
              mode,
              FILE_MODE_SIZE);
  write_decimal(&buffer[FILE_BYTE_SIZE_OFFSET],
                file.byte_size,
                FILE_BYTE_SIZE_SIZE);
  write_string(&buffer[FILE_ENDING_CHARS_OFFSET],
               FILE_HEADER_ENDING_CHARS,
               FILE_ENDING_CHARS_SIZE);
}

static bool needs_padding(int content_size) {
  return (content_size & 1) != 0;
}

int MemoryBuilder::open() {
  _buffer = unvoid_cast<uint8*>(malloc(AR_HEADER_SIZE));
  if (_buffer == null) return AR_OUT_OF_MEMORY;
  _size = AR_HEADER_SIZE;
  memcpy(_buffer, AR_HEADER, AR_HEADER_SIZE);
  return 0;
}

int MemoryBuilder::add(File file) {
  int needed_size = FILE_HEADER_SIZE + file.byte_size;
  if (needs_padding(file.byte_size)) needed_size++;
  int new_size = _size + needed_size;
  _buffer = unvoid_cast<uint8*>(realloc(_buffer, new_size));
  if (_buffer == null) return AR_OUT_OF_MEMORY;
  int offset = _size;
  write_ar_file_header(&_buffer[offset], file);
  offset += FILE_HEADER_SIZE;
  memcpy(&_buffer[offset], file.content(), file.byte_size);
  offset += file.byte_size;
  if (needs_padding(file.byte_size)) {
    _buffer[offset] = PADDING_CHAR;
  }
  _size = new_size;
  return 0;
}

int FileBuilder::open(const char* archive_path) {
  _file = fopen(archive_path, "wb");
  if (_file == NULL) return AR_ERRNO_ERROR;
  int written = fwrite(AR_HEADER, 1, AR_HEADER_SIZE, _file);
  if (written != AR_HEADER_SIZE) return AR_ERRNO_ERROR;
  return 0;
}

int FileBuilder::close() {
  if (_file != NULL) {
    int status = fclose(_file);
    if (status != 0) return AR_ERRNO_ERROR;
    return 0;
  }
  return 0;
}

int FileBuilder::add(File file) {
  uint8 buffer[FILE_HEADER_SIZE];
  write_ar_file_header(buffer, file);
  int written = fwrite(buffer, 1, FILE_HEADER_SIZE, _file);
  if (written != FILE_HEADER_SIZE) return AR_ERRNO_ERROR;
  written = fwrite(file.content(), 1, file.byte_size, _file);
  if (written != file.byte_size) return AR_ERRNO_ERROR;
  if (needs_padding(file.byte_size)) {
    written = fwrite(PADDING_STRING, 1, 1, _file);
    if (written != 1) return AR_ERRNO_ERROR;
  }
  return 0;
}

// Returns 0 on success.
// Returns a non-zero error code otherwise.
static int parse_ar_file_header(const uint8* data, File* file) {
  // We don't verify that the owner,group, or mode are correct.
  // However, we check that the ending characters are correct. (Easy enough to do).
  file->clear_name();
  file->clear_content();
  file->byte_size = 0;
  if (memcmp(FILE_HEADER_ENDING_CHARS, &data[FILE_ENDING_CHARS_OFFSET], FILE_ENDING_CHARS_SIZE) != 0) {
    return AR_FORMAT_ERROR;
  }

  // We parse the size first, as parsing the name can't lead to errors, and we
  // don't want to allocate memory if there is an error.
  int byte_size = 0;
  for (int i = 0; i < FILE_BYTE_SIZE_SIZE; i++) {
    char c = data[FILE_BYTE_SIZE_OFFSET + i];
    if ('0' <= c && c <= '9') {
      byte_size = byte_size * 10 + c - '0';
    } else if (c == ' ') {
      break;
    } else {
      return AR_FORMAT_ERROR;
    }
  }
  file->byte_size = byte_size;

  char name[FILE_NAME_SIZE + 1];
  memcpy(name, &data[FILE_NAME_OFFSET], FILE_NAME_SIZE);
  name[FILE_NAME_SIZE] = '\0';
  // Remove the padding.
  for (int i = FILE_NAME_SIZE - 1; i >= 0; i--) {
    if (name[i] == ' ') {
      name[i] = '\0';
    } else if (name[i] == '/') {
      // We also support the System V extension where '/' is used to terminate the name.
      name[i] = '\0';
      break;
    } else {
      break;
    }
  }
  file->set_name(strdup(name), AR_FREE);
  if (file->name() == null) return AR_OUT_OF_MEMORY;
  return 0;
}

int MemoryReader::next(File* file) {
  if (_offset == 0) {
    if (AR_HEADER_SIZE > _size) return AR_FORMAT_ERROR;
    if (memcmp(_buffer, AR_HEADER, AR_HEADER_SIZE) != 0) return AR_FORMAT_ERROR;
    _offset += AR_HEADER_SIZE;
  }
  if (_offset == _size) {
    file->clear_name();
    file->clear_content();
    file->byte_size = 0;
    return AR_END_OF_ARCHIVE;
  }
  if (_offset + FILE_HEADER_SIZE > _size) return AR_FORMAT_ERROR;
  int result = parse_ar_file_header(&_buffer[_offset], file);
  if (result != 0) return result;
  _offset += FILE_HEADER_SIZE;
  if (_offset + file->byte_size > _size) return AR_FORMAT_ERROR;
  file->set_content(&_buffer[_offset], AR_DONT_FREE);
  _offset += file->byte_size;
  if (needs_padding(file->byte_size)) _offset++;
  return 0;
}

int MemoryReader::find(const char* name, File* file, bool reset) {
  if (reset) {
    _offset = 0;
  }
  while (true) {
    int status = next(file);
    if (status != 0) {
      file->clear_name();
      file->clear_content();
      file->byte_size = 0;
      if (status == AR_END_OF_ARCHIVE) return AR_NOT_FOUND;
      return status;
    }
    if (strcmp(file->name(), name) == 0) {
      file->set_name(strdup(name), AR_FREE);
      return 0;
    }
  }
}

int FileReader::open(const char* archive_path) {
  _file = fopen(archive_path, "rb");
  if (_file == null) return AR_ERRNO_ERROR;
  return 0;
}

int FileReader::close() {
  if (_file != null) {
    int status = fclose(_file);
    if (status != 0) return AR_ERRNO_ERROR;
  }
  return 0;
}

int FileReader::next(File* file) {
  file->clear_name();
  file->clear_content();
  if (_is_first) {
    _is_first = false;
    int status = read_ar_header();
    if (status != 0) return status;
  }
  int status = read_file_header(file);
  if (status != 0) return status;
  status = read_file_content(file);
  if (status != 0) {
    ASSERT(status < 0) return status;
  }
  return 0;
}

int FileReader::find(const char* name, File* file, bool reset) {
  if (reset) {
    fseek(_file, 0L, SEEK_SET);
    _is_first = true;
  }
  if (_is_first) {
    int status = read_ar_header();
    if (status != 0) return status;
  }
  while (true) {
    int status = read_file_header(file);
    if (status == AR_END_OF_ARCHIVE) return AR_NOT_FOUND;
    if (status != 0) return status;
    if (strcmp(file->name(), name) == 0) {
      file->set_name(name, AR_DONT_FREE);
      status = read_file_content(file);
      return status;
    }
    status = skip_file_content(file);
    if (status != 0) return status;
  }
}

int FileReader::read_ar_header() {
  uint8 buffer[AR_HEADER_SIZE];
  int read = fread(&buffer, 1, AR_HEADER_SIZE, _file);
  if (read != AR_HEADER_SIZE) return AR_ERRNO_ERROR;
  if (memcmp(AR_HEADER, buffer, AR_HEADER_SIZE) != 0) return AR_FORMAT_ERROR;
  return 0;
}

int FileReader::read_file_header(File* file) {
  uint8 buffer[FILE_HEADER_SIZE];
  int read = fread(&buffer, 1, FILE_HEADER_SIZE, _file);
  if (read != FILE_HEADER_SIZE) {
    if (feof(_file)) return AR_END_OF_ARCHIVE;
    return AR_ERRNO_ERROR;
  }
  return parse_ar_file_header(buffer, file);
}

int FileReader::read_file_content(File* file) {
  uint8* content = unvoid_cast<uint8*>(malloc(file->byte_size));
  if (content == null) return AR_OUT_OF_MEMORY;
  int read = fread(content, 1, file->byte_size, _file);
  if (read != file->byte_size) {
    free(content);
    return AR_ERRNO_ERROR;
  }
  file->set_content(content, AR_FREE);
  if (needs_padding(file->byte_size)) {
    uint8 padding_char;
    read = fread(&padding_char, 1, 1, _file);
    if (read != 1 || padding_char != PADDING_CHAR) return AR_FORMAT_ERROR;
  }
  return 0;
}

int FileReader::skip_file_content(File* file) {
  int skip_count = file->byte_size;
  if (needs_padding(file->byte_size)) skip_count++;
  return fseek(_file, skip_count, SEEK_CUR);
}

} // namespace toit::Ar
} // namespace toit
