import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:args/args.dart';

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
        ..addOption(
          'port',
          abbr: 'p',
          help: 'Port to run the server on (default: 17007)',
          defaultsTo: '17007',
        );

  // Default port
  int? port;

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

    // Get port from arguments
    port = int.tryParse(argResults['port']);
  } catch (e) {
    stderr.writeln('Error parsing arguments: $e');
    stderr.writeln('');
    stderr.writeln('Usage: dart run <program> [options]');
    stderr.writeln('');
    stderr.writeln('Options:');
    stderr.writeln(parser.usage);
    exit(1);
  }

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

  final signedEvents = await launchSigner(events, port: port);

  for (final event in signedEvents) {
    print(jsonEncode(event));
  }

  exit(0);
}

Future<List<Map<String, dynamic>>> launchSigner(
  List<Map<String, dynamic>> events, {
  int? port,
}) async {
  // Create HTTP server with the configured port
  port ??= 17007;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  final url = 'http://localhost:$port/';

  final completer = Completer<List<Map<String, dynamic>>>();

  // Start the server first
  () async {
    await for (final request in server) {
      final path = request.uri.path;

      if (path == '/') {
        // Serve main HTML page
        request.response.headers.contentType = ContentType.html;
        request.response.write(getHtmlPage(events));
        await request.response.close();
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

            // Output signed events and close server
            completer.complete(signedEvents);
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
  }();

  // Give the server a moment to start up before opening the browser
  await Future.delayed(Duration(milliseconds: 100));

  // Open the browser automatically based on the operating system - without waiting
  if (Platform.isMacOS) {
    Process.run('open', [url]);
  } else if (Platform.isLinux) {
    Process.run('xdg-open', [url]);
  }

  // Wait for signed events and output them
  final signedEvents = await completer.future;

  // Close the server
  await server.close();

  return signedEvents;
}

String getHtmlPage(List<Map<String, dynamic>> events) {
  final encodedEvents = jsonEncode(events);

  return '''
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Nostr Event Signer</title>
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
    pre {
      background-color: #2a2a2a;
      color: #e0e0e0;
      padding: 10px;
      border-radius: 5px;
      overflow-x: auto;
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
    .status {
      margin-top: 20px;
      font-weight: bold;
    }
    .error {
      color: #ff6b6b;
    }
    #close-button {
      background-color: #2196F3;
      display: none;
    }
  </style>
</head>
<body>
  <h1>Nostr Event Signer</h1>
  <p>This page will help you sign Nostr events using your browser extension (NIP-07).</p>
  
  <div id="status">Ready to sign ${events.length} events</div>
  <button id="sign-all">Sign All Events</button>
  <button id="close-button">Close and Process Events</button>
  
  <div id="events-container"></div>
  
  <script>
    // The events that need to be signed
    const events = JSON.parse('$encodedEvents');
    const signedEvents = [];
    
    // Initialize the UI
    document.addEventListener('DOMContentLoaded', () => {
      const container = document.getElementById('events-container');
      
      events.forEach((event, index) => {
        const eventDiv = document.createElement('div');
        eventDiv.className = 'event';
        eventDiv.id = `event-\${index}`;
        
        const pre = document.createElement('pre');
        pre.textContent = JSON.stringify(event, null, 2);
        
        eventDiv.appendChild(pre);
        container.appendChild(eventDiv);
      });
      
      // Check if NIP-07 is available
      if (!window.nostr) {
        document.getElementById('status').innerHTML = '<span class="error">Error: No Nostr extension detected. Please install a NIP-07 compatible browser extension.</span>';
        document.getElementById('sign-all').disabled = true;
      }
    });
    
    // Sign events when button is clicked
    document.getElementById('sign-all').addEventListener('click', async () => {
      const button = document.getElementById('sign-all');
      const statusDiv = document.getElementById('status');
      
      if (!window.nostr) {
        statusDiv.innerHTML = '<span class="error">Error: No Nostr extension detected</span>';
        return;
      }
      
      button.disabled = true;
      statusDiv.textContent = 'Signing events...';
      
      try {
        for (let i = 0; i < events.length; i++) {
          statusDiv.textContent = `Signing event \${i+1} of \${events.length}...`;
          
          const event = events[i];
          const signedEvent = await signEvent(event);
          signedEvents.push(signedEvent);
          
          // Update UI to show signed event
          const eventDiv = document.getElementById(`event-\${i}`);
          eventDiv.className = 'event signed';
          
          const pre = eventDiv.querySelector('pre');
          pre.textContent = JSON.stringify(signedEvent, null, 2);
        }
        
        // All events signed, send back to the server
        statusDiv.textContent = 'All events signed! Sending back to server...';
        
        const response = await fetch('/signed-events', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify(signedEvents)
        });
        
        if (response.ok) {
          statusDiv.textContent = 'Success! All events are signed and ready to process.';
          // Show the close button
          const closeButton = document.getElementById('close-button');
          closeButton.style.display = 'inline-block';
        } else {
          throw new Error('Failed to send signed events to server');
        }
      } catch (error) {
        console.error(error);
        statusDiv.innerHTML = `<span class="error">Error: \${error.message}</span>`;
        button.disabled = false;
      }
    });
    
    // Add event listener for close button
    document.getElementById('close-button').addEventListener('click', async () => {
      const statusDiv = document.getElementById('status');
      const closeButton = document.getElementById('close-button');
      
      try {
        // Send signed events to server again to trigger server shutdown
        closeButton.disabled = true;
        statusDiv.textContent = 'Processing events and closing...';
        
        const response = await fetch('/signed-events', {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify(signedEvents)
        });
        
        if (response.ok) {
          statusDiv.textContent = 'Events processed successfully! This window will close automatically.';
          // The server should exit after receiving the events
          setTimeout(() => {
            window.close();
            // Show message in case window doesn't close (some browsers block window.close())
            statusDiv.textContent = 'Server has exited. You may now close this tab.';
          }, 1000);
        } else {
          throw new Error('Failed to process events');
        }
      } catch (error) {
        console.error(error);
        // Check if this is a network error (which is expected when server shuts down)
        if (error.message.includes('NetworkError')) {
          // This is expected behavior - the server has shut down
          statusDiv.textContent = 'Server has exited. You may now close this tab.';
          // Try to close the window
          setTimeout(() => {
            window.close();
          }, 500);
        } else {
          // For other errors, show the error message
          statusDiv.innerHTML = `<span class="error">Error: \${error.message}</span>`;
          closeButton.disabled = false;
        }
      }
    });
    
    // Function to sign an event using NIP-07
    async function signEvent(event) {
      try {
        // If the event already has an id and sig, we'll skip signing
        if (event.id && event.sig) {
          return event;
        }
        
        // Create a copy of the event for signing
        const eventToSign = { ...event };
        
        // NIP-07 signing
        const signedEvent = await window.nostr.signEvent(eventToSign);
        return signedEvent;
      } catch (error) {
        console.error('Error signing event:', error);
        throw error;
      }
    }
  </script>
</body>
</html>
  ''';
}
