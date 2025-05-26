import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:args/args.dart';
import 'package:models/models.dart';

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

class NIP07Signer extends Signer {
  final int port;
  NIP07Signer(super.ref, {this.port = 17007});

  NIP07Browser? _browser;

  @override
  Future<void> initialize({bool active = true}) async {
    _browser = await NIP07Browser.start(port);
    internalSetPubkey(await _browser!.getPublicKey());
    return super.initialize(active: active);
  }

  @override
  Future<void> dispose() async {
    await _browser?.close();
    _browser = null;
    await super.dispose();
  }

  @override
  Future<List<E>> sign<E extends Model<dynamic>>(
    List<PartialModel<dynamic>> partialModels,
  ) async {
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
}

// Function to get public key without requiring a Signer instance
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

class NIP07Browser {
  final HttpServer server;
  final String url;
  bool _browserOpened = false;
  bool _shouldCloseBrowser = false;

  // Operation state
  String _mode = 'idle'; // 'idle', 'publicKey', or 'sign'
  List<Map<String, dynamic>>? _eventsToSign;
  Completer<String>? _publicKeyCompleter;
  Completer<List<Map<String, dynamic>>>? _signingCompleter;

  NIP07Browser._({required this.server, required this.url});

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
        'data': _mode == 'sign' ? _eventsToSign : null,
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

    _mode = 'idle';
    _eventsToSign = null;
    _browserOpened = false;

    await server.close();
  }

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
    #public-key-section, #signing-section {
      display: none;
    }
    #idle-section {
      text-align: center;
      padding: 50px 0;
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
  
  <div id="debug" class="debug"></div>
  
  <script>
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
    
    // Check if NIP-07 is available
    if (!window.nostr) {
      log('No NIP-07 extension found');
      document.body.innerHTML = '<div class="error" style="text-align: center; padding: 50px;"><h2>Error: No Nostr extension detected</h2><p>Please install a NIP-07 compatible browser extension.</p></div>';
    } else {
      log('NIP-07 extension detected');
      let displayedEventsSignatureForSigning = null;
      
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
          
          // Handle public key retrieval
          if (state.mode === 'publicKey') {
            handlePublicKeyRetrieval();
          }
          
          // Handle signing
          if (state.mode === 'sign') {
            handleEventSigning(state.data);
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
