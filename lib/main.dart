import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:args/args.dart';
import 'package:models/models.dart';

/// Entry point for the NIP-07 signer CLI application.
///
/// This application serves as a bridge between command-line tools and browser-based
/// Nostr signers that implement the NIP-07 specification. It can operate in two modes:
///
/// 1. **Public Key Retrieval**: Use `--pubkey` flag to get the public key from
///    the connected Nostr signer extension.
/// 2. **Event Signing**: Read JSON events from stdin and sign them using the
///    browser extension.
///
/// ## Command Line Arguments
///
/// - `--help, -h`: Show usage information
/// - `--pubkey`: Get public key instead of signing events
/// - `--port, -p`: Port to run the local server on (default: 17007)
///
/// ## Usage Examples
///
/// ```bash
/// # Get public key
/// dart lib/main.dart --pubkey
///
/// # Sign events from stdin
/// echo '{"kind": 1, "content": "Hello world", "tags": []}' | dart lib/main.dart
///
/// # Use custom port
/// dart lib/main.dart --port 8080
/// ```
///
/// The application automatically opens a browser window that connects to your
/// NIP-07 compatible Nostr extension for cryptographic operations.
void main(List<String> arguments) async {
  // Parse command line arguments
  final parser =
      ArgParser()
        ..addFlag(
          'help',
          abbr: 'h',
          help: 'Show usage information',
          negatable: false,
        )
        ..addFlag(
          'pubkey',
          help: 'Get public key instead of signing events',
          negatable: false,
        )
        ..addOption(
          'port',
          abbr: 'p',
          help: 'Port to run the server on (default: 17007)',
          defaultsTo: '17007',
        );

  // Default port
  int? port;
  bool getPubkey = false;

  try {
    final argResults = parser.parse(arguments);

    // Show help if requested
    if (argResults['help'] == true) {
      stderr.writeln('Usage: dart run <program> [options]');
      stderr.writeln('');
      stderr.writeln('Options:');
      stderr.writeln(parser.usage);
      exit(0);
    }

    // Get option values
    port = int.tryParse(argResults['port']);
    getPubkey = argResults['pubkey'] == true;
  } catch (e) {
    stderr.writeln('Error parsing arguments: $e');
    stderr.writeln('');
    stderr.writeln('Usage: dart run <program> [options]');
    stderr.writeln('');
    stderr.writeln('Options:');
    stderr.writeln(parser.usage);
    exit(1);
  }

  // Handle --pubkey option
  if (getPubkey) {
    try {
      // Use a dedicated function for public key retrieval
      final publicKey = await _getPublicKey(port: port);

      // Output to stdout
      print(publicKey);

      exit(0);
    } catch (e) {
      stderr.writeln('Error getting public key: $e');
      exit(1);
    }
  }

  // Normal event signing flow
  // Read JSON events from stdin
  final events = <Map<String, dynamic>>[];
  final input = stdin.transform(utf8.decoder).transform(LineSplitter());

  await for (final line in input) {
    try {
      final event = jsonDecode(line);
      events.add(event);
    } catch (e) {
      stderr.writeln('Error parsing JSON: $e');
    }
  }

  if (events.isEmpty) {
    stderr.writeln('No valid events were provided. Exiting.');
    exit(1);
  }

  final signedEvents = await _launchSigner(events, port: port);

  for (final event in signedEvents) {
    print(jsonEncode(event));
  }

  exit(0);
}

/// A NIP-07 compatible signer implementation that bridges CLI applications
/// with browser-based Nostr signing extensions.
///
/// This class implements the [Signer] interface and provides access to
/// cryptographic operations through a browser extension that supports
/// the NIP-07 specification (`window.nostr` API).
///
/// ## Features
///
/// - **Event Signing**: Sign Nostr events using the browser extension
/// - **Public Key Retrieval**: Get the user's public key
/// - **NIP-04 Encryption/Decryption**: Encrypt and decrypt messages (deprecated)
/// - **NIP-44 Encryption/Decryption**: Modern encryption and decryption
/// - **Automatic Browser Management**: Handles browser lifecycle automatically
///
/// ## Usage
///
/// ```dart
/// final signer = NIP07Signer(ref, port: 17007);
/// await signer.signIn();
///
/// // Sign events
/// final signedEvents = await signer.sign(partialEvents);
///
/// // Encrypt message
/// final encrypted = await signer.nip44Encrypt('Hello!', recipientPubkey);
///
/// await signer.signOut();
/// ```
///
/// The signer automatically launches a local HTTP server and opens a browser
/// window that interfaces with your NIP-07 compatible extension.
class NIP07Signer extends Signer {
  /// The port number for the local HTTP server.
  ///
  /// This server facilitates communication between the CLI application
  /// and the browser extension. Default is 17007.
  final int port;

  /// Creates a new NIP-07 signer instance.
  ///
  /// [ref] is the reference object required by the parent [Signer] class.
  /// [port] specifies the local server port (default: 17007).
  NIP07Signer(super.ref, {this.port = 17007});

  NIP07Browser? _browser;

  // Static cache for browser/extension availability
  static bool? _isAvailableCache;

  /// Initializes the signer and establishes connection with the browser extension.
  ///
  /// This method:
  /// 1. Starts the local HTTP server
  /// 2. Opens a browser window
  /// 3. Connects to the NIP-07 extension
  /// 4. Retrieves and caches the user's public key
  ///
  /// [setAsActive] determines if this signer becomes the active signer.
  /// [registerSigner] determines if this signer registers itself globally.
  ///
  /// Throws an exception if the browser extension is not available or
  /// if the connection fails.
  @override
  Future<void> signIn({setAsActive = true, registerSigner = true}) async {
    try {
      _browser = await NIP07Browser.start(port);
      internalSetPubkey(await _browser!.getPublicKey());
      return super.signIn(
        setAsActive: setAsActive,
        registerSigner: registerSigner,
      );
    } catch (e) {
      // Cache that browser/extension is not available
      _isAvailableCache = false;
      rethrow;
    }
  }

  /// Checks if a NIP-07 compatible browser extension is available.
  ///
  /// Returns `true` if an extension is available, `false` otherwise.
  /// The result is cached after the first failed attempt for performance.
  ///
  /// This is an optimistic check - it assumes availability unless
  /// a previous operation has failed.
  @override
  Future<bool> get isAvailable async {
    // Return cached result if we know it's not available
    if (_isAvailableCache == false) {
      return false;
    }

    // Otherwise assume it's available (optimistic approach)
    return _isAvailableCache ?? true;
  }

  /// Closes the connection to the browser extension and cleans up resources.
  ///
  /// This method:
  /// 1. Closes the browser window
  /// 2. Stops the local HTTP server
  /// 3. Calls the parent class cleanup
  ///
  /// Should be called when done with the signer to properly release resources.
  @override
  Future<void> signOut() async {
    await _browser?.close();
    _browser = null;
    await super.signOut();
  }

  /// Signs a list of partial Nostr events using the browser extension.
  ///
  /// Takes a list of [PartialModel] objects (unsigned events) and returns
  /// a list of fully signed [Model] objects with `id`, `pubkey`, and `sig` fields.
  ///
  /// [partialModels] is the list of events to sign. Each event should have
  /// at minimum: `kind`, `content`, `tags`, and `created_at` fields.
  ///
  /// Returns a list of signed events of type [E].
  ///
  /// Throws an exception if:
  /// - The browser extension is not available
  /// - The user rejects the signing request
  /// - There's a communication error with the extension
  ///
  /// ## Example
  ///
  /// ```dart
  /// final partialNote = PartialNote(content: 'Hello Nostr!');
  /// final signedNotes = await signer.sign([partialNote]);
  /// ```
  @override
  Future<List<E>> sign<E extends Model<dynamic>>(
    List<PartialModel<dynamic>> partialModels,
  ) async {
    try {
      if (_browser == null) {
        // For backward compatibility, if sign is called before initialize()
        final result = await _launchSigner(
          partialModels.map((p) => p.toMap()).toList(),
          port: port,
        );
        return _processSignedEvents(result);
      }

      final result = await _browser!.signEvents(
        partialModels.map((p) => p.toMap()).toList(),
      );
      return _processSignedEvents(result);
    } catch (e) {
      // Cache that browser/extension is not available
      _isAvailableCache = false;
      rethrow;
    }
  }

  List<E> _processSignedEvents<E extends Model<dynamic>>(
    List<Map<String, dynamic>> result,
  ) {
    return result
        .map((r) {
          final int kind = r['kind'];
          return Model.getConstructorForKind(kind)!.call(r, ref);
        })
        .cast<E>()
        .toList();
  }

  /// Decrypts a message using NIP-04 (deprecated encryption standard).
  ///
  /// [encryptedMessage] is the encrypted message to decrypt.
  /// [senderPubkey] is the public key of the message sender.
  ///
  /// Returns the decrypted plaintext message.
  ///
  /// Throws an exception if:
  /// - The browser extension doesn't support NIP-04
  /// - The decryption fails
  /// - The extension is not available
  ///
  /// **Note**: NIP-04 is deprecated. Use [nip44Decrypt] for new applications.
  @override
  Future<String> nip04Decrypt(
    String encryptedMessage,
    String senderPubkey,
  ) async {
    _browser ??= await NIP07Browser.start(port);

    try {
      return await _browser!.nip04Decrypt(encryptedMessage, senderPubkey);
    } catch (e) {
      _isAvailableCache = false;
      rethrow;
    }
  }

  /// Encrypts a message using NIP-04 (deprecated encryption standard).
  ///
  /// [message] is the plaintext message to encrypt.
  /// [recipientPubkey] is the public key of the intended recipient.
  ///
  /// Returns the encrypted message.
  ///
  /// Throws an exception if:
  /// - The browser extension doesn't support NIP-04
  /// - The encryption fails
  /// - The extension is not available
  ///
  /// **Note**: NIP-04 is deprecated. Use [nip44Encrypt] for new applications.
  @override
  Future<String> nip04Encrypt(String message, String recipientPubkey) async {
    _browser ??= await NIP07Browser.start(port);

    try {
      return await _browser!.nip04Encrypt(message, recipientPubkey);
    } catch (e) {
      _isAvailableCache = false;
      rethrow;
    }
  }

  /// Decrypts a message using NIP-44 (modern encryption standard).
  ///
  /// [encryptedMessage] is the encrypted message to decrypt.
  /// [senderPubkey] is the public key of the message sender.
  ///
  /// Returns the decrypted plaintext message.
  ///
  /// Throws an exception if:
  /// - The browser extension doesn't support NIP-44
  /// - The decryption fails
  /// - The extension is not available
  ///
  /// NIP-44 provides improved security over the deprecated NIP-04 standard.
  @override
  Future<String> nip44Decrypt(
    String encryptedMessage,
    String senderPubkey,
  ) async {
    _browser ??= await NIP07Browser.start(port);

    try {
      return await _browser!.nip44Decrypt(encryptedMessage, senderPubkey);
    } catch (e) {
      _isAvailableCache = false;
      rethrow;
    }
  }

  /// Encrypts a message using NIP-44 (modern encryption standard).
  ///
  /// [message] is the plaintext message to encrypt.
  /// [recipientPubkey] is the public key of the intended recipient.
  ///
  /// Returns the encrypted message.
  ///
  /// Throws an exception if:
  /// - The browser extension doesn't support NIP-44
  /// - The encryption fails
  /// - The extension is not available
  ///
  /// NIP-44 provides improved security over the deprecated NIP-04 standard
  /// and should be used for all new applications.
  @override
  Future<String> nip44Encrypt(String message, String recipientPubkey) async {
    _browser ??= await NIP07Browser.start(port);

    try {
      return await _browser!.nip44Encrypt(message, recipientPubkey);
    } catch (e) {
      _isAvailableCache = false;
      rethrow;
    }
  }
}

/// Retrieves the public key from a NIP-07 browser extension.
///
/// This is a convenience function that starts a browser instance, retrieves
/// the public key from the connected NIP-07 extension, and then properly
/// cleans up the browser resources.
///
/// [port] is the port number for the local HTTP server. If not provided,
/// defaults to 17007.
///
/// Returns the user's public key as a hexadecimal string.
///
/// Throws an exception if:
/// - No NIP-07 extension is available
/// - The extension denies access to the public key
/// - There's a communication error
///
/// This function is primarily used by the CLI when the `--pubkey` flag is specified.
Future<String> _getPublicKey({int? port}) async {
  port ??= 17007;

  // Start a browser instance
  final browser = await NIP07Browser.start(port);

  try {
    // Get the public key
    final publicKey = await browser.getPublicKey();
    return publicKey;
  } finally {
    // Always close the browser server
    await browser.close();
  }
}

/// Signs a list of events using a temporary browser instance.
///
/// This is a convenience function for the CLI interface that creates a
/// browser instance, signs the provided events, and then disposes of
/// the browser resources.
///
/// [events] is a list of event maps to sign. Each event should contain
/// the basic Nostr event fields (`kind`, `content`, `tags`, etc.).
///
/// [port] is the port number for the local HTTP server. If not provided,
/// defaults to 17007.
///
/// Returns a list of signed event maps with `id`, `pubkey`, and `sig` fields added.
///
/// Throws an exception if:
/// - No NIP-07 extension is available
/// - The user rejects the signing request
/// - There's a communication error with the extension
///
/// This function is used internally by the CLI and as a fallback for backward compatibility.
Future<List<Map<String, dynamic>>> _launchSigner(
  List<Map<String, dynamic>> events, {
  int? port,
}) async {
  // This is a convenience function for the CLI interface
  // It initializes a browser, signs events, and then disposes the browser
  port ??= 17007;

  // Start a browser instance
  final browser = await NIP07Browser.start(port);

  try {
    // Sign the events
    final signedEvents = await browser.signEvents(events);
    return signedEvents;
  } finally {
    // Always close the browser server
    await browser.close();
  }
}

/// A browser-based interface for NIP-07 Nostr signing operations.
///
/// This class manages a local HTTP server that serves a web interface for
/// interacting with NIP-07 compatible browser extensions. The web interface
/// handles various operations including public key retrieval, event signing,
/// and message encryption/decryption.
///
/// ## Architecture
///
/// The class works by:
/// 1. Starting a local HTTP server on the specified port
/// 2. Serving an HTML page that uses the `window.nostr` API
/// 3. Communicating with the browser page via HTTP endpoints
/// 4. Automatically opening the user's default browser
///
/// ## Supported Operations
///
/// - **Public Key Retrieval**: Get the user's Nostr public key
/// - **Event Signing**: Sign Nostr events with the user's private key
/// - **NIP-04 Encryption/Decryption**: Legacy encryption (deprecated)
/// - **NIP-44 Encryption/Decryption**: Modern encryption standard
///
/// ## Lifecycle
///
/// ```dart
/// // Start browser interface
/// final browser = await NIP07Browser.start(17007);
///
/// // Perform operations
/// final pubkey = await browser.getPublicKey();
/// final signed = await browser.signEvents(events);
///
/// // Clean up
/// await browser.close();
/// ```
///
/// The browser automatically opens when operations are requested and can be
/// configured to close when the server shuts down.
class NIP07Browser {
  /// The underlying HTTP server instance.
  final HttpServer server;

  /// The URL where the browser interface is accessible.
  final String url;

  bool _browserOpened = false;
  bool _shouldCloseBrowser = false;

  // Operation state
  String _mode =
      'idle'; // 'idle', 'publicKey', 'sign', 'nip04Decrypt', 'nip04Encrypt', 'nip44Decrypt', 'nip44Encrypt'
  List<Map<String, dynamic>>? _eventsToSign;
  Completer<String>? _publicKeyCompleter;
  Completer<List<Map<String, dynamic>>>? _signingCompleter;

  // Encryption/decryption completers and data
  Completer<String>? _encryptionCompleter;
  Map<String, dynamic>? _encryptionData;

  NIP07Browser._({required this.server, required this.url});

  /// Creates and starts a new browser interface on the specified port.
  ///
  /// [port] is the port number for the local HTTP server.
  ///
  /// Returns a [NIP07Browser] instance that's ready to handle operations.
  ///
  /// The method:
  /// 1. Binds an HTTP server to localhost on the specified port
  /// 2. Sets up request handlers for the web interface
  /// 3. Automatically opens the user's default browser
  ///
  /// Throws an exception if:
  /// - The port is already in use
  /// - The server cannot be started
  /// - The browser cannot be opened
  static Future<NIP07Browser> start(int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final url = 'http://localhost:$port/';

    final browser = NIP07Browser._(server: server, url: url);

    // Set up a single listener for all requests
    browser._setupRequestHandler();

    // Open the browser
    await browser._openBrowser();

    return browser;
  }

  void _setupRequestHandler() {
    server.listen((request) async {
      try {
        await _handleRequest(request);
      } catch (e) {
        // Handle any errors during request processing
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write('Internal Server Error: $e');
          await request.response.close();
        } catch (_) {
          // Response might already be closed, ignore
        }
      }
    });
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;

    if (path == '/') {
      // Serve our unified HTML page
      request.response.headers.contentType = ContentType.html;
      request.response.write(getHtmlPage());
      await request.response.close();
    } else if (path == '/api/shutdown') {
      // Check if browser should close
      final response = {'shouldClose': _shouldCloseBrowser};
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    } else if (path == '/api/state') {
      // API endpoint that returns the current state/mode
      final stateData = {
        'mode': _mode,
        'data': _mode == 'sign' ? _eventsToSign : _encryptionData,
      };

      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(stateData));
      await request.response.close();
    } else if (path == '/public-key') {
      // Handle public key from the client
      if (request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        try {
          final data = jsonDecode(content);
          final publicKey = data['publicKey'] as String;

          request.response.statusCode = HttpStatus.ok;
          await request.response.close();

          // Only complete if we have an active completer
          if (_publicKeyCompleter != null &&
              !_publicKeyCompleter!.isCompleted) {
            _publicKeyCompleter!.complete(publicKey);
            // Reset mode to idle after completing
            _mode = 'idle';
          }
        } catch (e) {
          print('Error processing public key: $e');
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write('Invalid JSON format: $e');
          await request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
      }
    } else if (path == '/signed-events') {
      // Handle signed events from the client
      if (request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        try {
          final signedEvents = List<Map<String, dynamic>>.from(
            jsonDecode(content),
          );
          request.response.statusCode = HttpStatus.ok;
          await request.response.close();

          if (_signingCompleter != null && !_signingCompleter!.isCompleted) {
            _signingCompleter!.complete(signedEvents);
            // Reset mode to idle after completing
            _mode = 'idle';
            _eventsToSign = null;
          }
        } catch (e) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write('Invalid JSON format');
          await request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
      }
    } else if (path == '/encryption-result') {
      // Handle encryption/decryption results from the client
      if (request.method == 'POST') {
        final content = await utf8.decoder.bind(request).join();
        try {
          final data = jsonDecode(content);
          final result = data['result'] as String?;
          final error = data['error'] as String?;

          request.response.statusCode = HttpStatus.ok;
          await request.response.close();

          if (_encryptionCompleter != null &&
              !_encryptionCompleter!.isCompleted) {
            if (error != null) {
              _encryptionCompleter!.completeError(Exception(error));
            } else if (result != null) {
              _encryptionCompleter!.complete(result);
            }
            // Reset mode to idle after completing
            _mode = 'idle';
            _encryptionData = null;
          }
        } catch (e) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write('Invalid JSON format');
          await request.response.close();
        }
      } else {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
      }
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  Future<void> _openBrowser() async {
    if (!_browserOpened) {
      // Open the browser automatically based on the operating system
      if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      }

      // Give the browser some time to open
      await Future.delayed(Duration(milliseconds: 500));
      _browserOpened = true;
    }
  }

  /// Closes the browser interface and shuts down the HTTP server.
  ///
  /// This method:
  /// 1. Signals the browser window to close
  /// 2. Cancels any pending operations
  /// 3. Resets internal state
  /// 4. Shuts down the HTTP server
  ///
  /// Should be called when done with the browser to properly clean up resources.
  /// All pending operations will be cancelled with an error.
  Future<void> close() async {
    // Signal the browser to close
    _shouldCloseBrowser = true;

    // Give the browser a moment to detect the shutdown signal
    await Future.delayed(Duration(seconds: 1));

    // Cancel any pending operations
    if (_publicKeyCompleter != null && !_publicKeyCompleter!.isCompleted) {
      _publicKeyCompleter!.completeError(Exception('Server closed'));
    }

    if (_signingCompleter != null && !_signingCompleter!.isCompleted) {
      _signingCompleter!.completeError(Exception('Server closed'));
    }

    if (_encryptionCompleter != null && !_encryptionCompleter!.isCompleted) {
      _encryptionCompleter!.completeError(Exception('Server closed'));
    }

    _mode = 'idle';
    _eventsToSign = null;
    _encryptionData = null;
    _browserOpened = false;

    await server.close();
  }

  /// Retrieves the user's public key from the NIP-07 extension.
  ///
  /// This method communicates with the browser interface to request the
  /// user's public key from their connected Nostr extension.
  ///
  /// Returns the public key as a hexadecimal string.
  ///
  /// Throws an exception if:
  /// - No NIP-07 extension is available in the browser
  /// - The user denies access to their public key
  /// - There's a communication error
  ///
  /// The browser window will automatically open if not already open.
  Future<String> getPublicKey() async {
    // Set up for public key retrieval
    _mode = 'publicKey';
    _eventsToSign = null;
    _signingCompleter = null;
    _publicKeyCompleter = Completer<String>();

    // Make sure browser is open
    await _openBrowser();

    return _publicKeyCompleter!.future;
  }

  /// Signs a list of Nostr events using the NIP-07 extension.
  ///
  /// [events] is a list of event maps to sign. Each event should contain
  /// the standard Nostr event fields (`kind`, `content`, `tags`, `created_at`).
  ///
  /// Returns a list of signed events with `id`, `pubkey`, and `sig` fields added.
  ///
  /// Throws an exception if:
  /// - No NIP-07 extension is available in the browser
  /// - The user rejects the signing request
  /// - Any of the events are malformed
  /// - There's a communication error
  ///
  /// The browser window will show the events to be signed and request
  /// user confirmation before proceeding.
  Future<List<Map<String, dynamic>>> signEvents(
    List<Map<String, dynamic>> events,
  ) async {
    // Set up for signing
    _mode = 'sign';
    _publicKeyCompleter = null;
    _eventsToSign = events;
    _signingCompleter = Completer<List<Map<String, dynamic>>>();

    // Make sure browser is open
    await _openBrowser();

    return _signingCompleter!.future;
  }

  /// Decrypts a message using NIP-04 encryption (deprecated).
  ///
  /// [encryptedMessage] is the encrypted message string to decrypt.
  /// [senderPubkey] is the public key of the message sender.
  ///
  /// Returns the decrypted plaintext message.
  ///
  /// Throws an exception if:
  /// - The NIP-07 extension doesn't support NIP-04
  /// - The decryption fails (invalid message or key)
  /// - There's a communication error
  ///
  /// **Warning**: NIP-04 is deprecated due to security concerns.
  /// Use [nip44Decrypt] for new applications.
  Future<String> nip04Decrypt(
    String encryptedMessage,
    String senderPubkey,
  ) async {
    // Set up for nip04 decryption
    _mode = 'nip04Decrypt';
    _publicKeyCompleter = null;
    _signingCompleter = null;
    _eventsToSign = null;
    _encryptionData = {
      'encryptedMessage': encryptedMessage,
      'senderPubkey': senderPubkey,
    };
    _encryptionCompleter = Completer<String>();

    // Make sure browser is open
    await _openBrowser();

    return _encryptionCompleter!.future;
  }

  /// Encrypts a message using NIP-04 encryption (deprecated).
  ///
  /// [message] is the plaintext message to encrypt.
  /// [recipientPubkey] is the public key of the intended recipient.
  ///
  /// Returns the encrypted message string.
  ///
  /// Throws an exception if:
  /// - The NIP-07 extension doesn't support NIP-04
  /// - The encryption fails
  /// - There's a communication error
  ///
  /// **Warning**: NIP-04 is deprecated due to security concerns.
  /// Use [nip44Encrypt] for new applications.
  Future<String> nip04Encrypt(String message, String recipientPubkey) async {
    // Set up for nip04 encryption
    _mode = 'nip04Encrypt';
    _publicKeyCompleter = null;
    _signingCompleter = null;
    _eventsToSign = null;
    _encryptionData = {'message': message, 'recipientPubkey': recipientPubkey};
    _encryptionCompleter = Completer<String>();

    // Make sure browser is open
    await _openBrowser();

    return _encryptionCompleter!.future;
  }

  /// Decrypts a message using NIP-44 encryption (modern standard).
  ///
  /// [encryptedMessage] is the encrypted message string to decrypt.
  /// [senderPubkey] is the public key of the message sender.
  ///
  /// Returns the decrypted plaintext message.
  ///
  /// Throws an exception if:
  /// - The NIP-07 extension doesn't support NIP-44
  /// - The decryption fails (invalid message or key)
  /// - There's a communication error
  ///
  /// NIP-44 provides improved security over the deprecated NIP-04 standard
  /// and should be used for all new applications.
  Future<String> nip44Decrypt(
    String encryptedMessage,
    String senderPubkey,
  ) async {
    // Set up for nip44 decryption
    _mode = 'nip44Decrypt';
    _publicKeyCompleter = null;
    _signingCompleter = null;
    _eventsToSign = null;
    _encryptionData = {
      'encryptedMessage': encryptedMessage,
      'senderPubkey': senderPubkey,
    };
    _encryptionCompleter = Completer<String>();

    // Make sure browser is open
    await _openBrowser();

    return _encryptionCompleter!.future;
  }

  /// Encrypts a message using NIP-44 encryption (modern standard).
  ///
  /// [message] is the plaintext message to encrypt.
  /// [recipientPubkey] is the public key of the intended recipient.
  ///
  /// Returns the encrypted message string.
  ///
  /// Throws an exception if:
  /// - The NIP-07 extension doesn't support NIP-44
  /// - The encryption fails
  /// - There's a communication error
  ///
  /// NIP-44 provides improved security over the deprecated NIP-04 standard
  /// and should be used for all new applications.
  Future<String> nip44Encrypt(String message, String recipientPubkey) async {
    // Set up for nip44 encryption
    _mode = 'nip44Encrypt';
    _publicKeyCompleter = null;
    _signingCompleter = null;
    _eventsToSign = null;
    _encryptionData = {'message': message, 'recipientPubkey': recipientPubkey};
    _encryptionCompleter = Completer<String>();

    // Make sure browser is open
    await _openBrowser();

    return _encryptionCompleter!.future;
  }

  /// Generates the HTML page served by the browser interface.
  ///
  /// This method returns the complete HTML content for the web interface
  /// that communicates with NIP-07 browser extensions. The page includes:
  ///
  /// - JavaScript code to interact with `window.nostr` API
  /// - UI for displaying events to be signed
  /// - Forms for encryption/decryption operations
  /// - Real-time communication with the local server
  ///
  /// The generated page automatically detects the current operation mode
  /// and displays the appropriate interface to the user.
  ///
  /// Returns a complete HTML document as a string.
  String getHtmlPage() {
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>NIP-07 Signer for CLI</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      max-width: 800px;
      margin: 0 auto;
      padding: 20px;
      line-height: 1.6;
      background-color: #121212;
      color: #e0e0e0;
    }
    .status {
      margin-top: 20px;
      font-weight: bold;
    }
    .error {
      color: #ff6b6b;
    }
    pre {
      background-color: #2a2a2a;
      color: #e0e0e0;
      padding: 10px;
      border-radius: 5px;
      overflow-x: auto;
      position: relative;
    }
    .event {
      border: 1px solid #444;
      padding: 15px;
      margin-bottom: 15px;
      border-radius: 5px;
      background-color: #1e1e1e;
    }
    .event.signed {
      background-color: #1f3d2f;
      border-color: #2d6a4f;
    }
    button {
      background-color: #4CAF50;
      color: white;
      padding: 10px 15px;
      border: none;
      border-radius: 4px;
      cursor: pointer;
      font-size: 16px;
      margin-right: 10px;
    }
    button:disabled {
      background-color: #3a3a3a;
      cursor: not-allowed;
    }
    .debug {
      margin-top: 20px;
      font-size: 0.8em;
      color: #888;
    }
    #public-key-section, #signing-section, #encryption-section {
      display: none;
    }
    #idle-section {
      text-align: center;
      padding: 50px 0;
    }
    .input-group {
      margin-bottom: 15px;
    }
    .input-group label {
      display: block;
      margin-bottom: 5px;
      font-weight: bold;
    }
    .input-group input, .input-group textarea {
      width: 100%;
      padding: 8px;
      border: 1px solid #444;
      border-radius: 4px;
      background-color: #2a2a2a;
      color: #e0e0e0;
      box-sizing: border-box;
    }
    .input-group textarea {
      height: 100px;
      resize: vertical;
    }
    /* JSON Syntax Highlighting */
    .json-key { color: #9cdcfe; }
    .json-string { color: #ce9178; }
    .json-number { color: #b5cea8; }
    .json-boolean { color: #569cd6; }
    .json-null { color: #569cd6; }
  </style>
</head>
<body>
  <h1>NIP-07 Signer for CLI</h1>
  
  <div id="idle-section">
    <p>Waiting for operation...</p>
  </div>
  
  <div id="public-key-section">
    <h2>Public Key Retrieval</h2>
    <div id="pk-status" class="status">Checking for NIP-07 extension...</div>
    <pre id="public-key"></pre>
  </div>
  
  <div id="signing-section">
    <h3 id="sign-status" class="status">Ready to sign events</h3>
    <button id="sign-all">Sign All Events</button>
    <p></p>
    <p>After signing this window will automatically close and signed events sent to the terminal.</p>
    <p></p>
    <div id="events-container"></div>
  </div>
  
  <div id="encryption-section">
    <h2 id="encryption-title">Encryption Operation</h2>
    <div id="encryption-status" class="status">Processing...</div>
    <div id="encryption-inputs"></div>
    <button id="execute-encryption" style="display: none;">Execute</button>
    <pre id="encryption-result" style="display: none;"></pre>
  </div>
  
  <div id="debug" class="debug"></div>
  
  <script type="module">
    // JSON Syntax Highlighting Function
    function highlightJSON(json) {
      return json.replace(/("(\\u[a-zA-Z0-9]{4}|\\[^u]|[^\\\\"])*"(\\s*:)?|\b(true|false|null)\b|-?\\d+(?:\\.\\d*)?(?:[eE][+\\-]?\\d+)?)/g, function (match) {
        let cls = 'json-number';
        if (/^"/.test(match)) {
          if (/:\$/.test(match)) {
            cls = 'json-key';
          } else {
            cls = 'json-string';
          }
        } else if (/true|false/.test(match)) {
          cls = 'json-boolean';
        } else if (/null/.test(match)) {
          cls = 'json-null';
        }
        return '<span class="' + cls + '">' + match + '</span>';
      });
    }

    // Function to update pre content with syntax highlighting
    function updatePreContent(preElement, content) {
      preElement.innerHTML = highlightJSON(content);
    }

    // Utilities
    const debugDiv = document.getElementById('debug');
    
    function log(message) {
      console.log(message);
      debugDiv.innerHTML += `<div>\${message}</div>`;
    }
    
    // Sections
    const idleSection = document.getElementById('idle-section');
    const publicKeySection = document.getElementById('public-key-section');
    const signingSection = document.getElementById('signing-section');
    const encryptionSection = document.getElementById('encryption-section');

    // Wait for next event loop to allow window.nostr to be injected
    // This is nessiary for the nos2x-fox extension
    await new Promise((resolve) => setTimeout(resolve, 0));
    
    // Check if NIP-07 is available
    if (!window.nostr) {
      log('No NIP-07 extension found');
      document.body.innerHTML = '<div class="error" style="text-align: center; padding: 50px;"><h2>Error: No Nostr extension detected</h2><p>Please install a NIP-07 compatible browser extension.</p></div>';
    } else {
      log('NIP-07 extension detected');
      let displayedEventsSignatureForSigning = null;
      let currentEncryptionMode = null;
      
      // Function to get current state
      async function checkState() {
        try {
          const response = await fetch('/api/state');
          if (!response.ok) {
            throw new Error(`Server error: \${response.status}`);
          }
          
          const state = await response.json();
          
          // Update UI based on state
          idleSection.style.display = state.mode === 'idle' ? 'block' : 'none';
          publicKeySection.style.display = state.mode === 'publicKey' ? 'block' : 'none';
          signingSection.style.display = state.mode === 'sign' ? 'block' : 'none';
          encryptionSection.style.display = ['nip04Decrypt', 'nip04Encrypt', 'nip44Decrypt', 'nip44Encrypt'].includes(state.mode) ? 'block' : 'none';
          
          // Handle public key retrieval
          if (state.mode === 'publicKey') {
            handlePublicKeyRetrieval();
          }
          
          // Handle signing
          if (state.mode === 'sign') {
            handleEventSigning(state.data);
          }
          
          // Handle encryption operations
          if (['nip04Decrypt', 'nip04Encrypt', 'nip44Decrypt', 'nip44Encrypt'].includes(state.mode)) {
            handleEncryptionOperation(state.mode, state.data);
          }
          
          return state;
        } catch (error) {
          log(`Error checking state: \${error.message}`);
          return { mode: 'error' };
        }
      }
      
      // Handle public key retrieval
      async function handlePublicKeyRetrieval() {
        const statusDiv = document.getElementById('pk-status');
        const publicKeyPre = document.getElementById('public-key');
        
        try {
          // Get public key using NIP-07
          statusDiv.textContent = 'Retrieving public key...';
          const publicKey = await window.nostr.getPublicKey();
          log(`Public key retrieved: \${publicKey}`);
          updatePreContent(publicKeyPre, publicKey);
          statusDiv.textContent = 'Public key retrieved successfully!';
          
          // Send public key to server
          const payload = JSON.stringify({ publicKey });
          
          const response = await fetch('/public-key', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json'
            },
            body: payload
          });
          
          log(`Server response status: \${response.status}`);
          
          if (response.ok) {
            statusDiv.textContent = 'Public key sent to server successfully.';
          } else {
            const responseText = await response.text();
            throw new Error(`Server returned error \${response.status}: \${responseText}`);
          }
        } catch (error) {
          console.error(error);
          log(`Error: \${error.message}`);
          statusDiv.innerHTML = `<span class="error">Error: \${error.message}</span>`;
        }
      }
      
      // Handle event signing
      async function handleEventSigning(events) {
        const newSignature = JSON.stringify(events || []);

        if (newSignature === displayedEventsSignatureForSigning) {
          return;
        }

        log('New event data for signing. Refreshing signing UI.');
        const statusDiv = document.getElementById('sign-status');
        const container = document.getElementById('events-container');
        const signAllButton = document.getElementById('sign-all');

        container.innerHTML = '';

        if (!events || events.length === 0) {
          statusDiv.textContent = 'No events to sign.';
          signAllButton.style.display = 'none';
          displayedEventsSignatureForSigning = newSignature;
          return;
        }

        signAllButton.style.display = 'inline-block';
        
        // Count events by kind
        const kindCounts = events.reduce((acc, event) => {
          const kind = event.kind;
          acc[kind] = (acc[kind] || 0) + 1;
          return acc;
        }, {});
        
        // Create status message with kind breakdown
        const kindBreakdown = Object.entries(kindCounts)
          .map(([kind, count]) => `kind \${kind} (\${count} events)`)
          .join(', ');
        statusDiv.textContent = `Ready to sign: \${kindBreakdown}`;
        
        events.forEach((event, index) => {
          const eventDiv = document.createElement('div');
          eventDiv.className = 'event';
          eventDiv.id = `event-\${index}`;
          
          const pre = document.createElement('pre');
          updatePreContent(pre, JSON.stringify(event, null, 2));
          
          eventDiv.appendChild(pre);
          container.appendChild(eventDiv);
        });
        
        displayedEventsSignatureForSigning = newSignature;
        
        signAllButton.onclick = async () => {
          signAllButton.disabled = true;
          statusDiv.textContent = 'Signing events...';
          
          try {
            const signedEvents = [];
            
            for (let i = 0; i < events.length; i++) {
              statusDiv.textContent = `Signing event \${i+1} of \${events.length}...`;
              
              const event = events[i];
              if (event.id && event.sig) {
                signedEvents.push(event);
                continue;
              }
              
              const eventToSign = { ...event };
              const signedEvent = await window.nostr.signEvent(eventToSign);
              signedEvents.push(signedEvent);
              
              const eventDiv = document.getElementById(`event-\${i}`);
              eventDiv.className = 'event signed';
              
              const pre = eventDiv.querySelector('pre');
              updatePreContent(pre, JSON.stringify(signedEvent, null, 2));
            }
            
            statusDiv.textContent = 'All events signed! Sending back to server...';
            
            const response = await fetch('/signed-events', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json'
              },
              body: JSON.stringify(signedEvents)
            });
            
            if (response.ok) {
              statusDiv.textContent = 'Success! All events are signed and sent to server.';
            } else {
              throw new Error('Failed to send signed events to server');
            }
          } catch (error) {
            console.error(error);
            statusDiv.innerHTML = `<span class="error">Error: \${error.message}</span>`;
            signAllButton.disabled = false;
          }
        };
      }
      
      // Handle encryption operations
      async function handleEncryptionOperation(mode, data) {
        if (mode === currentEncryptionMode) {
          return; // Already handling this mode
        }
        
        currentEncryptionMode = mode;
        
        const titleDiv = document.getElementById('encryption-title');
        const statusDiv = document.getElementById('encryption-status');
        const inputsDiv = document.getElementById('encryption-inputs');
        const executeButton = document.getElementById('execute-encryption');
        const resultPre = document.getElementById('encryption-result');
        
        // Reset UI
        executeButton.style.display = 'none';
        resultPre.style.display = 'none';
        inputsDiv.innerHTML = '';
        
        // Set title and initial status
        const operationNames = {
          'nip04Decrypt': 'NIP-04 Decryption',
          'nip04Encrypt': 'NIP-04 Encryption',
          'nip44Decrypt': 'NIP-44 Decryption',
          'nip44Encrypt': 'NIP-44 Encryption'
        };
        
        titleDiv.textContent = operationNames[mode];
        statusDiv.textContent = 'Ready to execute operation';
        
        // Show operation details
        if (data) {
          const detailsHTML = Object.entries(data)
            .map(([key, value]) => `<div class="input-group">
              <label>\${key}:</label>
              <textarea readonly>\${value}</textarea>
            </div>`)
            .join('');
          
          inputsDiv.innerHTML = detailsHTML + '<p>Click Execute to perform the operation using your NIP-07 extension.</p>';
          executeButton.style.display = 'inline-block';
        }
        
        executeButton.onclick = async () => {
          executeButton.disabled = true;
          statusDiv.textContent = 'Executing operation...';
          
          try {
            let result;
            
            // Execute the appropriate operation
            if (mode === 'nip04Decrypt') {
              if (!window.nostr.nip04 || !window.nostr.nip04.decrypt) {
                throw new Error('NIP-04 decryption not supported by extension');
              }
              result = await window.nostr.nip04.decrypt(data.senderPubkey, data.encryptedMessage);
            } else if (mode === 'nip04Encrypt') {
              if (!window.nostr.nip04 || !window.nostr.nip04.encrypt) {
                throw new Error('NIP-04 encryption not supported by extension');
              }
              result = await window.nostr.nip04.encrypt(data.recipientPubkey, data.message);
            } else if (mode === 'nip44Decrypt') {
              if (!window.nostr.nip44 || !window.nostr.nip44.decrypt) {
                throw new Error('NIP-44 decryption not supported by extension');
              }
              result = await window.nostr.nip44.decrypt(data.senderPubkey, data.encryptedMessage);
            } else if (mode === 'nip44Encrypt') {
              if (!window.nostr.nip44 || !window.nostr.nip44.encrypt) {
                throw new Error('NIP-44 encryption not supported by extension');
              }
              result = await window.nostr.nip44.encrypt(data.recipientPubkey, data.message);
            }
            
            statusDiv.textContent = 'Operation completed successfully!';
            updatePreContent(resultPre, result);
            resultPre.style.display = 'block';
            
            // Send result to server
            const response = await fetch('/encryption-result', {
              method: 'POST',
              headers: {
                'Content-Type': 'application/json'
              },
              body: JSON.stringify({ result })
            });
            
            if (response.ok) {
              statusDiv.textContent = 'Result sent to server successfully.';
            } else {
              throw new Error('Failed to send result to server');
            }
          } catch (error) {
            console.error(error);
            statusDiv.innerHTML = `<span class="error">Error: \${error.message}</span>`;
            
            // Send error to server
            try {
              await fetch('/encryption-result', {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/json'
                },
                body: JSON.stringify({ error: error.message })
              });
            } catch (sendError) {
              log(`Failed to send error to server: \${sendError.message}`);
            }
            
            executeButton.disabled = false;
          }
        };
      }
      
      // Check if we should close the browser window
      async function checkShutdown() {
        try {
          const response = await fetch('/api/shutdown');
          if (!response.ok) {
            throw new Error(`Server error: \${response.status}`);
          }
          
          const data = await response.json();
          if (data.shouldClose) {
            log('Shutdown signal received. Closing browser window...');
            window.close();
            document.body.innerHTML = '<div style="text-align: center; padding: 50px;"><h2>Server is shutting down</h2><p>You can close this window now.</p></div>';
          }
        } catch (error) {
          log(`Error checking shutdown: \${error.message}. Attempting to close window.`);
          window.close();
        }
      }
      
      // Start checking state and shutdown status
      checkState();
      
      // Periodically check for state changes and shutdown signal
      setInterval(checkState, 2000);
      setInterval(checkShutdown, 1000);
    }
  </script>
</body>
</html>
    ''';
  }
}
