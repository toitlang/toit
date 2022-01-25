// Copyright (C) 2018 Toitware ApS.
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

#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "objects_inline.h"
#include "heap.h"
#include "os.h"
#include "uuid.h"
#include "vm.h"

namespace toit {

#ifndef TOIT_FREERTOS

namespace {

template <typename V>
class Node {
 public:
  Node(uword key, const V& value) : key(key), value(value), left(null), right(null) { }
  uword key;
  V value;
  Node<V>* left;
  Node<V>* right;
};

template <typename V>
class BinaryTree {
 public:
  BinaryTree() : ref_count(_new int(1)) { }
  BinaryTree(const BinaryTree& other)
      : ref_count(other.ref_count)
      , _size(other._size)
      , root(other.root) {
    (*ref_count)++;
  }

  ~BinaryTree() {
    (*ref_count)--;
    if (*ref_count == 0) {
      delete_nodes(root);
      delete ref_count;
    }
  }

  BinaryTree& operator=(const BinaryTree& other) {
    (*other.ref_count)++;
    (*ref_count)--;
    if (*ref_count == 0) {
      delete_nodes(root);
      delete ref_count;
    }
    ref_count = other.ref_count;
    _size = other._size;
    root = other.root;
    return *this;
  }

  void insert(uword key, const V& value) {
    ASSERT((*ref_count) == 1);
    // Mangle the key to give a more uniform distribution.
    key = hash(key);
    if (root == null) {
      _size++;
      root = _new Node<V>(key, value);
      return;
    }
    auto current = root;
    while (true) {
      if (key == current->key) {
        current->value = value;
        return;
      }
      if (key < current->key) {
        if (current->left == null) {
          _size++;
          current->left = _new Node<V>(key, value);
          return;
        }
        current = current->left;
        continue;
      }
      ASSERT(key > current->key);
      if (current->right == null) {
        _size++;
        current->right = _new Node<V>(key, value);
        return;
      }
      current = current->right;
    }
  }

  const std::pair<uword, V>* find(uword key) const {
    // Mangle the key to give a more uniform distribution.
    key = hash(key);
    auto current = root;
    while (true) {
      if (current == null) return null;
      if (key == current->key) {
        found.first = key;
        found.second = current->value;
        return &found;
      }
      if (key < current->key) {
        current = current->left;
      } else {
        current = current->right;
      }
    }
  }

  int size() const { return _size; }

 private:
  int* ref_count;
  int _size = 0;
  Node<V>* root = null;
  mutable std::pair<uword, V> found;

  void delete_nodes(Node<V>* node) {
    if (node == null) return;
    delete_nodes(node->left);
    delete_nodes(node->right);
    delete node;
  }

  uword hash(uword x) const {
    // Via https://github.com/skeeto/hash-prospector (Unlicense).
    x ^= x >> 16;
    x *= UINT32_C(0x7feb352d);
    x ^= x >> 15;
    x *= UINT32_C(0x846ca68b);
    x ^= x >> 16;
    return x;
  }
};

class BinaryTreeSet {
 public:
  void insert(uword key) { tree.insert(key, true); }
  const std::pair<uword, bool>* find(uword key) const {
    return tree.find(key);
  }
  const std::pair<uword, bool>* end() const { return null; }

  int size() const { return tree.size(); }

 private:
  BinaryTree<bool> tree;
};

template <typename V>
class BinaryTreeMap {
 public:
  void emplace(uword key, const V& value) { tree.insert(key, value); }
  const std::pair<uword, V>* find(uword key) const {
    return tree.find(key);
  }
  const std::pair<uword, V>* end() const { return null; }

  int size() const { return tree.size(); }

 private:
  BinaryTree<V> tree;
};

static int _align(int byte_size, int word_size = WORD_SIZE) {
  return (byte_size + (word_size - 1)) & ~(word_size - 1);
}

}  // Anonymous namespace.

class ImageAllocator : public HeapAllocator {
 public:
  bool initialize(int pointer_count, int byte_count);

  HeapObject* allocate_object(TypeTag tag, int length);

  ProtectableAlignedMemory* image() const { return _image; }

  void* memory() const { return _memory; }

  void set_program(Program* program) { _program = program; }

  void expand();

 protected:
  void* allocate(int byte_size);

 private:
  ProtectableAlignedMemory* _image = null;
  void* _memory = null;
  void* _top = null;

  Program* _program = null;

  // Returns the byte_size needed for the unfolded page aligned image.
  uword image_byte_size();
};

template <typename T>
using WorkAroundSet = BinaryTreeSet;

template <typename K, typename V>
using WorkAroundMap = BinaryTreeMap<V>;

ImageAllocator::allocate(int size) {

}

ProgramImage Snapshot::read_image() {
  ImageSnapshotReader reader(_buffer, _size);
  return reader.read_image();
}

class RelocationBits : public PointerCallback {
 public:
  RelocationBits(const ProgramImage& image)
      : _relocation_bits(_new word[image.byte_size() / PAYLOAD_SIZE])
  , _image(image) {
    ASSERT(image.byte_size() % PAYLOAD_SIZE == 0);
    memset(_relocation_bits, 0, WORD_SIZE * (image.byte_size() / PAYLOAD_SIZE));
  }

  bool get_bit_for(word* addr) {
    int word_index = word_index_for(addr);
    int bit_number = bit_number_for(addr);
    return (_relocation_bits[word_index] >> bit_number) & 1U;
  }

  word get_bits_for_payload(int n) {
    return _relocation_bits[n];
  }

 public:
  void object_address(Object** p) {
    // Only make heap objects relocatable.
    if ((*p)->is_heap_object()) set_bit_for(reinterpret_cast<word*>(p));
  }

  void c_address(void** p, bool is_sentinel) {
    // Only make non null pointers relocatable.
    if (*p != null) {
      word* value = (word*) *p;
      ASSERT(_image.address_inside(value) ||
             (is_sentinel && value == _image.address()) + _image.byte_size());
      set_bit_for(reinterpret_cast<word*>(p));
    }
  }

 private:
  static const int PAYLOAD_SIZE = WORD_BIT_SIZE * WORD_SIZE;

  word* _relocation_bits;
  ProgramImage _image;

  void set_bit_for(word* addr) {
    int word_index = word_index_for(addr);
    int bit_number = bit_number_for(addr);
    _relocation_bits[word_index] |= 1UL << bit_number;
    ASSERT(get_bit_for(addr));
  }

  int word_index_for(word* addr) {
    return distance_to(addr) / PAYLOAD_SIZE;
  }

  int bit_number_for(word* addr) {
    int result = (distance_to(addr) % PAYLOAD_SIZE) / WORD_SIZE;
    ASSERT(result >= 0 && result < WORD_BIT_SIZE);
    return result;
  }

  word distance_to(word* addr) {
    ASSERT(_image.address_inside(addr));
    return Utils::address_distance(_image.begin(), addr);
  }
};

RelocationBits* ImageInputStream::build_relocation_bits(const ProgramImage& image) {
  RelocationBits* result = _new RelocationBits(image);
  image.do_pointers(result);
  return result;
}

ImageInputStream::ImageInputStream(const ProgramImage& image,
                                   RelocationBits* relocation_bits)
    : _image(image)
    , relocation_bits(relocation_bits)
    , current(image.begin())
    , index(0) {
}

int ImageInputStream::words_to_read() {
  ASSERT(!eos());
  int ready_words = Utils::address_distance(current, _image.end()) / WORD_SIZE;
  return Utils::min(ImageOutputStream::CHUNK_SIZE, 1 + ready_words);
}

int ImageInputStream::read(word* buffer) {
  ASSERT(!eos());
  int pos = 1;
  while (pos <= WORD_BIT_SIZE && (current < _image.end())) {
    word value = *current;
    if (relocation_bits->get_bit_for(current)) {
      value = Utils::address_distance(_image.begin(), reinterpret_cast<word*>(value));
      // Sentinels may point to `_image.end()`.
      ASSERT(value <= (word) Utils::address_distance(_image.begin(), _image.end()));
    }
    current = Utils::address_at(current, WORD_SIZE);
    buffer[pos++] = value;
  }
  buffer[0] = relocation_bits->get_bits_for_payload(index++);
  return pos;
}

#endif  // TOIT_FREERTOS

ImageOutputStream::ImageOutputStream(ProgramImage image)
    : _image(image)
    , current(image.begin()) {}

void ImageOutputStream::write(const word* buffer, int size, word* output) {
  ASSERT(1 < size && size <= CHUNK_SIZE);
  if (output == null) output = current;
  // The input buffer is often part of network packets with various headers,
  // so the embedded words aren't guaranteed to be word-aligned.
  word mask = Utils::read_unaligned_word(&buffer[0]);
  for (int index = 1; index < size; index++) {
    word value = Utils::read_unaligned_word(&buffer[index]);
    // Relocate value if needed with the address of the image.
    if (mask & 1U) value += reinterpret_cast<word>(_image.begin());
    mask = mask >> 1;
    output[index - 1] = value;
    current++;
  }
}

}  // namespace toit
