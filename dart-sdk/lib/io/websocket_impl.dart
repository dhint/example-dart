// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of dart.io;

const String _webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

class _WebSocketMessageType {
  static const int NONE = 0;
  static const int BINARY = 1;
  static const int TEXT = 2;
}


class _WebSocketOpcode {
  static const int CONTINUATION = 0;
  static const int TEXT = 1;
  static const int BINARY = 2;
  static const int RESERVED_3 = 3;
  static const int RESERVED_4 = 4;
  static const int RESERVED_5 = 5;
  static const int RESERVED_6 = 6;
  static const int RESERVED_7 = 7;
  static const int CLOSE = 8;
  static const int PING = 9;
  static const int PONG = 10;
  static const int RESERVED_B = 11;
  static const int RESERVED_C = 12;
  static const int RESERVED_D = 13;
  static const int RESERVED_E = 14;
  static const int RESERVED_F = 15;
}

/**
 * The web socket protocol transformer handles the protocol byte stream
 * which is supplied through the [:handleData:]. As the protocol is processed,
 * it'll output frame data as either a List<int> or String.
 *
 * Important infomation about usage: Be sure you use cancelOnError, so the
 * socket will be closed when the processer encounter an error. Not using it
 * will lead to undefined behaviour.
 */
// TODO(ajohnsen): make this transformer reusable?
class _WebSocketProtocolTransformer implements StreamTransformer, EventSink {
  static const int START = 0;
  static const int LEN_FIRST = 1;
  static const int LEN_REST = 2;
  static const int MASK = 3;
  static const int PAYLOAD = 4;
  static const int CLOSED = 5;
  static const int FAILURE = 6;

  bool _serverSide;
  EventSink _eventSink;

  _WebSocketProtocolTransformer([bool this._serverSide = false]) {
    _prepareForNextFrame();
    _currentMessageType = _WebSocketMessageType.NONE;
  }

  Stream bind(Stream stream) {
    return new Stream.eventTransformed(
        stream,
        (EventSink eventSink) {
          if (_eventSink != null) {
            throw new StateError("WebSocket transformer already used.");
          }
          _eventSink = eventSink;
          return this;
        });
  }

  void addError(Object error, [StackTrace stackTrace]) {
    _eventSink.addError(error, stackTrace);
  }

  void close() => _eventSink.close();

  /**
   * Process data received from the underlying communication channel.
   */
  void add(Uint8List buffer) {
    int count = buffer.length;
    int index = 0;
    int lastIndex = count;
    try {
      if (_state == CLOSED) {
        throw new WebSocketException("Data on closed connection");
      }
      if (_state == FAILURE) {
        throw new WebSocketException("Data on failed connection");
      }
      while ((index < lastIndex) && _state != CLOSED && _state != FAILURE) {
        int byte = buffer[index];
        switch (_state) {
          case START:
            _fin = (byte & 0x80) != 0;
            if ((byte & 0x70) != 0) {
              // The RSV1, RSV2 bits RSV3 most be all zero.
              throw new WebSocketException("Protocol error");
            }
            _opcode = (byte & 0xF);
            switch (_opcode) {
            case _WebSocketOpcode.CONTINUATION:
              if (_currentMessageType == _WebSocketMessageType.NONE) {
                throw new WebSocketException("Protocol error");
              }
              break;

            case _WebSocketOpcode.TEXT:
              if (_currentMessageType != _WebSocketMessageType.NONE) {
                throw new WebSocketException("Protocol error");
              }
              _currentMessageType = _WebSocketMessageType.TEXT;
              _controller = new StreamController(sync: true);
              _controller.stream
                  .transform(UTF8.decoder)
                  .fold(new StringBuffer(), (buffer, str) => buffer..write(str))
                  .then((buffer) {
                    _eventSink.add(buffer.toString());
                  }, onError: _eventSink.addError);
              break;

            case _WebSocketOpcode.BINARY:
              if (_currentMessageType != _WebSocketMessageType.NONE) {
                throw new WebSocketException("Protocol error");
              }
              _currentMessageType = _WebSocketMessageType.BINARY;
              _controller = new StreamController(sync: true);
              _controller.stream
                  .fold(new BytesBuilder(), (buffer, data) => buffer..add(data))
                  .then((buffer) {
                    _eventSink.add(buffer.takeBytes());
                  }, onError: _eventSink.addError);
              break;

            case _WebSocketOpcode.CLOSE:
            case _WebSocketOpcode.PING:
            case _WebSocketOpcode.PONG:
              // Control frames cannot be fragmented.
              if (!_fin) throw new WebSocketException("Protocol error");
              break;

            default:
              throw new WebSocketException("Protocol error");
            }
            _state = LEN_FIRST;
            break;

          case LEN_FIRST:
            _masked = (byte & 0x80) != 0;
            _len = byte & 0x7F;
            if (_isControlFrame() && _len > 125) {
              throw new WebSocketException("Protocol error");
            }
            if (_len < 126) {
              _lengthDone();
            } else if (_len == 126) {
              _len = 0;
              _remainingLenBytes = 2;
              _state = LEN_REST;
            } else if (_len == 127) {
              _len = 0;
              _remainingLenBytes = 8;
              _state = LEN_REST;
            }
            break;

          case LEN_REST:
            _len = _len << 8 | byte;
            _remainingLenBytes--;
            if (_remainingLenBytes == 0) {
              _lengthDone();
            }
            break;

          case MASK:
            _maskingKey = _maskingKey << 8 | byte;
            _remainingMaskingKeyBytes--;
            if (_remainingMaskingKeyBytes == 0) {
              _maskDone();
            }
            break;

          case PAYLOAD:
            // The payload is not handled one byte at a time but in blocks.
            int payload;
            if (lastIndex - index <= _remainingPayloadBytes) {
              payload = lastIndex - index;
            } else {
              payload = _remainingPayloadBytes;
            }
            _remainingPayloadBytes -= payload;

            // Unmask payload if masked.
            if (_masked) {
              for (int i = 0; i < payload; i++) {
                int maskingByte =
                    ((_maskingKey >> ((3 - _unmaskingIndex) * 8)) & 0xFF);
                buffer[index + i] = buffer[index + i] ^ maskingByte;
                _unmaskingIndex = (_unmaskingIndex + 1) % 4;
              }
            }

            if (_isControlFrame()) {
              if (payload > 0) {
                // Allocate a buffer for collecting the control frame
                // payload if any.
                if (_controlPayload == null) {
                  _controlPayload = new List<int>();
                }
                _controlPayload.addAll(buffer.sublist(index, index + payload));
                index += payload;
              }

              if (_remainingPayloadBytes == 0) {
                _controlFrameEnd();
              }
            } else {
              if (_currentMessageType != _WebSocketMessageType.TEXT &&
                  _currentMessageType != _WebSocketMessageType.BINARY) {
                  throw new WebSocketException("Protocol error");
              }
              _controller.add(
                  new Uint8List.view(buffer.buffer, index, payload));
              index += payload;
              if (_remainingPayloadBytes == 0) {
                _messageFrameEnd();
              }
            }

            // Hack - as we always do index++ below.
            index--;
            break;
        }

        // Move to the next byte.
        index++;
      }
    } catch (e, stackTrace) {
      _state = FAILURE;
      _eventSink.addError(e, stackTrace);
    }
  }

  void _lengthDone() {
    if (_masked) {
      if (!_serverSide) {
        throw new WebSocketException("Received masked frame from server");
      }
      _state = MASK;
      _remainingMaskingKeyBytes = 4;
    } else {
      if (_serverSide) {
        throw new WebSocketException("Received unmasked frame from client");
      }
      _remainingPayloadBytes = _len;
      _startPayload();
    }
  }

  void _maskDone() {
    _remainingPayloadBytes = _len;
    _startPayload();
  }

  void _startPayload() {
    // If there is no actual payload perform perform callbacks without
    // going through the PAYLOAD state.
    if (_remainingPayloadBytes == 0) {
      if (_isControlFrame()) {
        switch (_opcode) {
          case _WebSocketOpcode.CLOSE:
            _state = CLOSED;
            _eventSink.close();
            break;
          case _WebSocketOpcode.PING:
            _eventSink.add(new _WebSocketPing());
            break;
          case _WebSocketOpcode.PONG:
            _eventSink.add(new _WebSocketPong());
            break;
        }
        _prepareForNextFrame();
      } else {
        _messageFrameEnd();
      }
    } else {
      _state = PAYLOAD;
    }
  }

  void _messageFrameEnd() {
    if (_fin) {
      switch (_currentMessageType) {
        case _WebSocketMessageType.TEXT:
          _controller.close();
          break;
        case _WebSocketMessageType.BINARY:
          _controller.close();
          break;
      }
      _controller = null;
      _currentMessageType = _WebSocketMessageType.NONE;
    }
    _prepareForNextFrame();
  }

  void _controlFrameEnd() {
    switch (_opcode) {
      case _WebSocketOpcode.CLOSE:
        closeCode = WebSocketStatus.NO_STATUS_RECEIVED;
        if (_controlPayload.length > 0) {
          if (_controlPayload.length == 1) {
            throw new WebSocketException("Protocol error");
          }
          closeCode = _controlPayload[0] << 8 | _controlPayload[1];
          if (closeCode == WebSocketStatus.NO_STATUS_RECEIVED) {
            throw new WebSocketException("Protocol error");
          }
          if (_controlPayload.length > 2) {
            closeReason = UTF8.decode(_controlPayload.sublist(2));
          }
        }
        _state = CLOSED;
        _eventSink.close();
        break;

      case _WebSocketOpcode.PING:
        _eventSink.add(new _WebSocketPing(_controlPayload));
        break;

      case _WebSocketOpcode.PONG:
        _eventSink.add(new _WebSocketPong(_controlPayload));
        break;
    }
    _prepareForNextFrame();
  }

  bool _isControlFrame() {
    return _opcode == _WebSocketOpcode.CLOSE ||
           _opcode == _WebSocketOpcode.PING ||
           _opcode == _WebSocketOpcode.PONG;
  }

  void _prepareForNextFrame() {
    if (_state != CLOSED && _state != FAILURE) _state = START;
    _fin = null;
    _opcode = null;
    _len = null;
    _masked = null;
    _maskingKey = 0;
    _remainingLenBytes = null;
    _remainingMaskingKeyBytes = null;
    _remainingPayloadBytes = null;
    _unmaskingIndex = 0;
    _controlPayload = null;
  }

  int _state;
  bool _fin;
  int _opcode;
  int _len;
  bool _masked;
  int _maskingKey;
  int _remainingLenBytes;
  int _remainingMaskingKeyBytes;
  int _remainingPayloadBytes;
  int _unmaskingIndex;

  int _currentMessageType;
  List<int> _controlPayload;
  StreamController _controller;

  int closeCode = WebSocketStatus.NO_STATUS_RECEIVED;
  String closeReason = "";
}


class _WebSocketPing {
  final List<int> payload;
  _WebSocketPing([this.payload = null]);
}


class _WebSocketPong {
  final List<int> payload;
  _WebSocketPong([this.payload = null]);
}


class _WebSocketTransformerImpl implements WebSocketTransformer {
  final StreamController<WebSocket> _controller =
      new StreamController<WebSocket>(sync: true);

  Stream<WebSocket> bind(Stream<HttpRequest> stream) {
    stream.listen((request) {
        _upgrade(request)
            .then((WebSocket webSocket) => _controller.add(webSocket))
            .catchError(_controller.addError);
    });

    return _controller.stream;
  }

  static Future<WebSocket> _upgrade(HttpRequest request) {
    var response = request.response;
    if (!_isUpgradeRequest(request)) {
      // Send error response and drain the request.
      request.listen((_) {}, onDone: () {
        response.statusCode = HttpStatus.BAD_REQUEST;
        response.contentLength = 0;
        response.close();
      });
      return new Future.error(
          new WebSocketException("Invalid WebSocket upgrade request"));
    }

    // Send the upgrade response.
    response.statusCode = HttpStatus.SWITCHING_PROTOCOLS;
    response.headers.add(HttpHeaders.CONNECTION, "Upgrade");
    response.headers.add(HttpHeaders.UPGRADE, "websocket");
    String key = request.headers.value("Sec-WebSocket-Key");
    _SHA1 sha1 = new _SHA1();
    sha1.add("$key$_webSocketGUID".codeUnits);
    String accept = _CryptoUtils.bytesToBase64(sha1.close());
    response.headers.add("Sec-WebSocket-Accept", accept);
    response.headers.contentLength = 0;
    return response.detachSocket()
        .then((socket) => new _WebSocketImpl._fromSocket(socket, true));
  }

  static bool _isUpgradeRequest(HttpRequest request) {
    if (request.method != "GET") {
      return false;
    }
    if (request.headers[HttpHeaders.CONNECTION] == null) {
      return false;
    }
    bool isUpgrade = false;
    request.headers[HttpHeaders.CONNECTION].forEach((String value) {
      if (value.toLowerCase() == "upgrade") isUpgrade = true;
    });
    if (!isUpgrade) return false;
    String upgrade = request.headers.value(HttpHeaders.UPGRADE);
    if (upgrade == null || upgrade.toLowerCase() != "websocket") {
      return false;
    }
    String version = request.headers.value("Sec-WebSocket-Version");
    if (version == null || version != "13") {
      return false;
    }
    String key = request.headers.value("Sec-WebSocket-Key");
    if (key == null) {
      return false;
    }
    return true;
  }
}


// TODO(ajohnsen): Make this transformer reusable.
class _WebSocketOutgoingTransformer implements StreamTransformer, EventSink {
  final _WebSocketImpl webSocket;
  EventSink _eventSink;

  _WebSocketOutgoingTransformer(_WebSocketImpl this.webSocket);

  Stream bind(Stream stream) {
    return new Stream.eventTransformed(
        stream,
        (EventSink eventSink) {
          if (_eventSink != null) {
            throw new StateError("WebSocket transformer already used");
          }
          _eventSink = eventSink;
          return this;
        });
  }

  void add(message) {
    if (message is _WebSocketPong) {
      addFrame(_WebSocketOpcode.PONG, message.payload);
      return;
    }
    if (message is _WebSocketPing) {
      addFrame(_WebSocketOpcode.PING, message.payload);
      return;
    }
    List<int> data;
    int opcode;
    if (message != null) {
      if (message is String) {
        opcode = _WebSocketOpcode.TEXT;
        data = UTF8.encode(message);
      } else {
        if (message is !List<int>) {
          throw new ArgumentError(message);
        }
        opcode = _WebSocketOpcode.BINARY;
        data = message;
      }
    } else {
      opcode = _WebSocketOpcode.TEXT;
    }
    addFrame(opcode, data);
  }

  void addError(Object error, [StackTrace stackTrace]) {
    _eventSink.addError(error, stackTrace);
  }

  void close() {
    int code = webSocket._outCloseCode;
    String reason = webSocket._outCloseReason;
    List<int> data;
    if (code != null) {
      data = new List<int>();
      data.add((code >> 8) & 0xFF);
      data.add(code & 0xFF);
      if (reason != null) {
        data.addAll(UTF8.encode(reason));
      }
    }
    addFrame(_WebSocketOpcode.CLOSE, data);
    _eventSink.close();
  }

  void addFrame(int opcode, List<int> data) {
    createFrame(opcode, data, webSocket._serverSide).forEach(_eventSink.add);
  }

  static Iterable createFrame(int opcode, List<int> data, bool serverSide) {
    bool mask = !serverSide;  // Masking not implemented for server.
    int dataLength = data == null ? 0 : data.length;
    // Determine the header size.
    int headerSize = (mask) ? 6 : 2;
    if (dataLength > 65535) {
      headerSize += 8;
    } else if (dataLength > 125) {
      headerSize += 2;
    }
    List<int> header = new List<int>(headerSize);
    int index = 0;
    // Set FIN and opcode.
    header[index++] = 0x80 | opcode;
    // Determine size and position of length field.
    int lengthBytes = 1;
    int firstLengthByte = 1;
    if (dataLength > 65535) {
      header[index++] = 127;
      lengthBytes = 8;
    } else if (dataLength > 125) {
      header[index++] = 126;
      lengthBytes = 2;
    }
    // Write the length in network byte order into the header.
    for (int i = 0; i < lengthBytes; i++) {
      header[index++] = dataLength >> (((lengthBytes - 1) - i) * 8) & 0xFF;
    }
    if (mask) {
      header[1] |= 1 << 7;
      var maskBytes = _IOCrypto.getRandomBytes(4);
      header.setRange(index, index + 4, maskBytes);
      index += 4;
      if (data != null) {
        var list;
        // If this is a text message just do the masking inside the
        // encoded data.
        if (opcode == _WebSocketOpcode.TEXT) {
          list = data;
        } else {
          list = new Uint8List(data.length);
        }
        if (data is Uint8List) {
          for (int i = 0; i < data.length; i++) {
            list[i] = data[i] ^ maskBytes[i % 4];
          }
        } else {
          for (int i = 0; i < data.length; i++) {
            if (data[i] < 0 || 255 < data[i]) {
              throw new ArgumentError(
                  "List element is not a byte value "
                  "(value ${data[i]} at index $i)");
            }
            list[i] = data[i] ^ maskBytes[i % 4];
          }
        }
        data = list;
      }
    }
    assert(index == headerSize);
    if (data == null) {
      return [header];
    } else {
      return [header, data];
    }
  }
}


class _WebSocketConsumer implements StreamConsumer {
  final _WebSocketImpl webSocket;
  final Socket socket;
  StreamController _controller;
  StreamSubscription _subscription;
  bool _issuedPause = false;
  bool _closed = false;
  Completer _closeCompleter = new Completer();
  Completer _completer;

  _WebSocketConsumer(_WebSocketImpl this.webSocket, Socket this.socket);

  void _onListen() {
    if (_subscription != null) {
      _subscription.cancel();
    }
  }

  void _onPause() {
    if (_subscription != null) {
      _subscription.pause();
    } else {
      _issuedPause = true;
    }
  }

  void _onResume() {
    if (_subscription != null) {
      _subscription.resume();
    } else {
      _issuedPause = false;
    }
  }

  void _cancel() {
    if (_subscription != null) {
      var subscription = _subscription;
      _subscription = null;
      subscription.cancel();
    }
  }

  _ensureController() {
    if (_controller != null) return;
    _controller = new StreamController(sync: true,
                                       onPause: _onPause,
                                       onResume: _onResume,
                                       onCancel: _onListen);
    var stream = _controller.stream.transform(
        new _WebSocketOutgoingTransformer(webSocket));
    socket.addStream(stream)
        .then((_) {
          _done();
          _closeCompleter.complete(webSocket);
        }, onError: (error, StackTrace stackTrace) {
          _closed = true;
          _cancel();
          if (error is ArgumentError) {
            if (!_done(error, stackTrace)) {
              _closeCompleter.completeError(error, stackTrace);
            }
          } else {
            _done();
            _closeCompleter.complete(webSocket);
          }
        });
  }

  bool _done([error, StackTrace stackTrace]) {
    if (_completer == null) return false;
    if (error != null) {
      _completer.completeError(error, stackTrace);
    } else {
      _completer.complete(webSocket);
    }
    _completer = null;
    return true;
  }

  Future addStream(var stream) {
    if (_closed) {
      stream.listen(null).cancel();
      return new Future.value(webSocket);
    }
    _ensureController();
    _completer = new Completer();
    _subscription = stream.listen(
        (data) {
          _controller.add(data);
        },
        onDone: _done,
        onError: _done,
        cancelOnError: true);
    if (_issuedPause) {
      _subscription.pause();
      _issuedPause = false;
    }
    return _completer.future;
  }

  Future close() {
    _ensureController();
    Future closeSocket() {
      return socket.close().catchError((_) {}).then((_) => webSocket);
    }
    _controller.close();
    return _closeCompleter.future.then((_) => closeSocket());
  }

  void add(data) {
    if (_closed) return;
    _ensureController();
    _controller.add(data);
  }

  void closeSocket() {
    _closed = true;
    _cancel();
    close();
  }
}


class _WebSocketImpl extends Stream implements WebSocket {
  StreamController _controller;
  StreamSubscription _subscription;
  StreamSink _sink;

  final Socket _socket;
  final bool _serverSide;
  int _readyState = WebSocket.CONNECTING;
  bool _writeClosed = false;
  int _closeCode;
  String _closeReason;
  Duration _pingInterval;
  Timer _pingTimer;
  _WebSocketConsumer _consumer;

  int _outCloseCode;
  String _outCloseReason;

  static final HttpClient _httpClient = new HttpClient();

  static Future<WebSocket> connect(String url, [protocols]) {
    Uri uri = Uri.parse(url);
    if (uri.scheme != "ws" && uri.scheme != "wss") {
      throw new WebSocketException("Unsupported URL scheme '${uri.scheme}'");
    }
    if (uri.userInfo != "") {
      throw new WebSocketException("Unsupported user info '${uri.userInfo}'");
    }

    Random random = new Random();
    // Generate 16 random bytes.
    List<int> nonceData = new List<int>(16);
    for (int i = 0; i < 16; i++) {
      nonceData[i] = random.nextInt(256);
    }
    String nonce = _CryptoUtils.bytesToBase64(nonceData);

    uri = new Uri(scheme: uri.scheme == "wss" ? "https" : "http",
                  userInfo: uri.userInfo,
                  host: uri.host,
                  port: uri.port,
                  path: uri.path,
                  query: uri.query,
                  fragment: uri.fragment);
    return _httpClient.openUrl("GET", uri)
      .then((request) {
        // Setup the initial handshake.
        request.headers.add(HttpHeaders.CONNECTION, "upgrade");
        request.headers.set(HttpHeaders.UPGRADE, "websocket");
        request.headers.set("Sec-WebSocket-Key", nonce);
        request.headers.set("Sec-WebSocket-Version", "13");
        return request.close();
      })
      .then((response) {
        void error(String message) {
          // Flush data.
          response.detachSocket().then((socket) {
            socket.destroy();
          });
          throw new WebSocketException(message);
        }
        if (response.statusCode != HttpStatus.SWITCHING_PROTOCOLS ||
            response.headers[HttpHeaders.CONNECTION] == null ||
            !response.headers[HttpHeaders.CONNECTION].any(
                (value) => value.toLowerCase() == "upgrade") ||
            response.headers.value(HttpHeaders.UPGRADE).toLowerCase() !=
                "websocket") {
          error("Connection to '$uri' was not upgraded to websocket");
        }
        String accept = response.headers.value("Sec-WebSocket-Accept");
        if (accept == null) {
          error("Response did not contain a 'Sec-WebSocket-Accept' header");
        }
        _SHA1 sha1 = new _SHA1();
        sha1.add("$nonce$_webSocketGUID".codeUnits);
        List<int> expectedAccept = sha1.close();
        List<int> receivedAccept = _CryptoUtils.base64StringToBytes(accept);
        if (expectedAccept.length != receivedAccept.length) {
          error("Reasponse header 'Sec-WebSocket-Accept' is the wrong length");
        }
        for (int i = 0; i < expectedAccept.length; i++) {
          if (expectedAccept[i] != receivedAccept[i]) {
            error("Bad response 'Sec-WebSocket-Accept' header");
          }
        }
        return response.detachSocket()
            .then((socket) => new _WebSocketImpl._fromSocket(socket));
      });
  }

  _WebSocketImpl._fromSocket(Socket this._socket,
                             [bool this._serverSide = false]) {
    _consumer = new _WebSocketConsumer(this, _socket);
    _sink = new _StreamSinkImpl(_consumer);
    _readyState = WebSocket.OPEN;

    var transformer = new _WebSocketProtocolTransformer(_serverSide);
    _subscription = _socket.transform(transformer).listen(
        (data) {
          if (data is _WebSocketPing) {
            if (!_writeClosed) _consumer.add(new _WebSocketPong(data.payload));
          } else if (data is _WebSocketPong) {
            // Simply set pingInterval, as it'll cancel any timers.
            pingInterval = _pingInterval;
          } else {
            _controller.add(data);
          }
        },
        onError: (error) {
          if (error is FormatException) {
            _close(WebSocketStatus.INVALID_FRAME_PAYLOAD_DATA);
          } else {
            _close(WebSocketStatus.PROTOCOL_ERROR);
          }
          _controller.close();
        },
        onDone: () {
          if (_readyState == WebSocket.OPEN) {
            _readyState = WebSocket.CLOSING;
            if (!_isReservedStatusCode(transformer.closeCode)) {
              _close(transformer.closeCode);
            } else {
              _close();
            }
            _readyState = WebSocket.CLOSED;
          }
          _closeCode = transformer.closeCode;
          _closeReason = transformer.closeReason;
          _controller.close();
        },
        cancelOnError: true);
    _subscription.pause();
    _controller = new StreamController(sync: true,
                                       onListen: _subscription.resume,
                                       onPause: _subscription.pause,
                                       onResume: _subscription.resume);
  }

  StreamSubscription listen(void onData(message),
                            {Function onError,
                             void onDone(),
                             bool cancelOnError}) {
    return _controller.stream.listen(onData,
                                     onError: onError,
                                     onDone: onDone,
                                     cancelOnError: cancelOnError);
  }

  Duration get pingInterval => _pingInterval;

  void set pingInterval(Duration interval) {
    if (_writeClosed) return;
    if (_pingTimer != null) _pingTimer.cancel();
    _pingInterval = interval;

    if (_pingInterval == null) return;

    _pingTimer = new Timer(_pingInterval, () {
      if (_writeClosed) return;
      _consumer.add(new _WebSocketPing());
      _pingTimer = new Timer(_pingInterval, () {
        // No pong received.
        _close(WebSocketStatus.GOING_AWAY);
      });
    });
  }

  int get readyState => _readyState;

  String get extensions => null;
  String get protocol => null;
  int get closeCode => _closeCode;
  String get closeReason => _closeReason;

  void add(data) => _sink.add(data);
  void addError(error) => _sink.addError(error);
  Future addStream(Stream stream) => _sink.addStream(stream);
  Future get done => _sink.done;

  Future close([int code, String reason]) {
    if (_isReservedStatusCode(code)) {
      throw new WebSocketException("Reserved status code $code");
    }
    if (_outCloseCode == null) {
      _outCloseCode = code;
      _outCloseReason = reason;
    }
    return _sink.close();
  }

  void _close([int code, String reason]) {
    if (_writeClosed) return;
    if (_outCloseCode == null) {
      _outCloseCode = code;
      _outCloseReason = reason;
    }
    _writeClosed = true;
    _consumer.closeSocket();
  }

  static bool _isReservedStatusCode(int code) {
    return code != null &&
           (code < WebSocketStatus.NORMAL_CLOSURE ||
            code == WebSocketStatus.RESERVED_1004 ||
            code == WebSocketStatus.NO_STATUS_RECEIVED ||
            code == WebSocketStatus.ABNORMAL_CLOSURE ||
            (code > WebSocketStatus.INTERNAL_SERVER_ERROR &&
             code < WebSocketStatus.RESERVED_1015) ||
            (code >= WebSocketStatus.RESERVED_1015 &&
             code < 3000));
  }
}