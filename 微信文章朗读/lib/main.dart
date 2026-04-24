import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '微信文章朗读',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const ReaderPage(),
    );
  }
}

class ReaderPage extends StatefulWidget {
  const ReaderPage({super.key});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  late WebViewController _webViewController;
  late FlutterTts _flutterTts;
  
  final TextEditingController _urlController = TextEditingController();
  List<String> _textChunks = [];
  int _currentChunkIndex = 0;
  bool _isPlaying = false;
  bool _isLoading = false;
  bool _isPaused = false;
  bool _isPageLoaded = false;
  bool _pendingRead = false;
  double _speechRate = 1.0;
  Timer? _scrollTimer;

  @override
  void initState() {
    super.initState();
    _initWebView();
    _initTTS();
  }

  void _initWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() {
              _isPageLoaded = false;
              _textChunks = [];
            });
          },
          onPageFinished: (String url) {
            setState(() {
              _isPageLoaded = true;
              _isLoading = false;
            });
            _extractArticleText();
            _hidePageElements();
          },
        ),
      );
  }

  void _initTTS() {
    _flutterTts = FlutterTts();
    _flutterTts.setLanguage("zh-CN");
    _flutterTts.setPitch(1.0);
    _flutterTts.setSpeechRate(_speechRate);
    
    _flutterTts.setCompletionHandler(() {
      if (_isPlaying && !_isPaused) {
        _readNextChunk();
      }
    });
  }

  void _hidePageElements() {
    _webViewController.runJavaScript('''
      (function() {
        var style = document.createElement('style');
        style.textContent = `
          #js_pc_qr_code, #js_article_comment, .rich_media_tool, 
          .qr_code_pc, .reward_area, #content_bottom_area, 
          #js_tags_wrap, #js_share_area, .original_primary_tip,
          #js_mp_qrcode, .rich_media_area_extra, #js_video_page,
          .mp-side-menu, .rich_media_content_extra {
            display: none !important;
          }
        `;
        document.head.appendChild(style);
      })();
    ''');
  }

  Future<void> _extractArticleText() async {
    try {
      final result = await _webViewController.runJavaScriptReturningResult('''
        (function() {
          var container = document.getElementById('js_content') || 
                         document.querySelector('.rich_media_content') ||
                         document.querySelector('#content');
          if (!container) return '';
          
          var elements = container.querySelectorAll('p, h1, h2, h3, section');
          var texts = [];
          
          for (var i = 0; i < elements.length; i++) {
            var el = elements[i];
            var text = el.innerText.trim();
            
            if (text.length < 5) continue;
            
            var lowerText = text.toLowerCase();
            var skipWords = [
              'javascript', 'var ', 'function', 'window.', 'document.',
              '原创', '收录于话题', '以下文章来源于', '点击关注', 
              '点上方', '长按识别', '扫码关注', '阅读原文',
              '写留言', '精选留言', '赞', '分享'
            ];
            
            var shouldSkip = false;
            for (var j = 0; j < skipWords.length; j++) {
              if (lowerText.includes(skipWords[j]) || text.includes(skipWords[j])) {
                shouldSkip = true;
                break;
              }
            }
            
            if (!shouldSkip) {
              texts.push(text);
            }
          }
          
          return texts.join('');
        })();
      ''');
      
      String fullText = result.toString().replaceAll(RegExp(r'^"|"$'), '');
      if (fullText.isNotEmpty && fullText.length > 10) {
        List<String> chunks = _splitTextIntoChunks(fullText, 150);
        setState(() {
          _textChunks = chunks;
          _currentChunkIndex = 0;
        });
        
        if (_pendingRead) {
          _pendingRead = false;
          _startReading();
        }
      }
    } catch (e) {
      print('提取文章文本失败: $e');
    }
  }

  List<String> _splitTextIntoChunks(String text, int maxChunkSize) {
    List<String> chunks = [];
    int start = 0;
    
    while (start < text.length) {
      int end = start + maxChunkSize;
      if (end >= text.length) {
        chunks.add(text.substring(start));
        break;
      }
      
      int breakPoint = text.lastIndexOf('。', end);
      if (breakPoint == -1 || breakPoint <= start) {
        breakPoint = text.lastIndexOf('！', end);
      }
      if (breakPoint == -1 || breakPoint <= start) {
        breakPoint = text.lastIndexOf('？', end);
      }
      if (breakPoint == -1 || breakPoint <= start) {
        breakPoint = text.lastIndexOf('，', end);
      }
      if (breakPoint == -1 || breakPoint <= start) {
        breakPoint = end;
      } else {
        breakPoint += 1;
      }
      
      chunks.add(text.substring(start, breakPoint));
      start = breakPoint;
    }
    
    return chunks.where((c) => c.trim().isNotEmpty).toList();
  }

  Future<void> _onPlayPressed() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showMessage('请输入微信公众号文章链接');
      return;
    }

    if (!url.startsWith('http')) {
      _showMessage('请输入有效的链接');
      return;
    }

    _flutterTts.stop();
    _stopAutoScroll();
    
    setState(() {
      _isLoading = true;
      _isPlaying = false;
      _isPaused = false;
      _textChunks = [];
      _currentChunkIndex = 0;
      _pendingRead = true;
    });

    try {
      await _webViewController.loadRequest(Uri.parse(url));
      _showMessage('加载中，完成后自动朗读...');
    } catch (e) {
      _showMessage('加载失败，请检查链接');
      setState(() {
        _isLoading = false;
        _pendingRead = false;
      });
    }
  }

  void _readNextChunk() {
    if (_currentChunkIndex < _textChunks.length) {
      _flutterTts.speak(_textChunks[_currentChunkIndex]);
      _currentChunkIndex++;
    } else {
      setState(() {
        _isPlaying = false;
      });
      _stopAutoScroll();
      _showMessage('朗读完成');
    }
  }

  void _startReading() {
    if (_textChunks.isEmpty) {
      _showMessage('文章内容为空');
      return;
    }

    setState(() {
      _isPlaying = true;
      _isPaused = false;
    });

    _readNextChunk();
    _startAutoScroll();
  }

  void _pauseReading() {
    setState(() {
      _isPaused = true;
    });

    _flutterTts.pause();
    _stopAutoScroll();
  }

  void _resumeReading() {
    setState(() {
      _isPaused = false;
    });

    _startAutoScroll();
    _readNextChunk();
  }

  void _stopReading() {
    setState(() {
      _isPlaying = false;
      _isPaused = false;
      _currentChunkIndex = 0;
    });

    _flutterTts.stop();
    _stopAutoScroll();
  }

  void _startAutoScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) {
      _webViewController.runJavaScript('''
        (function() {
          var maxScroll = document.documentElement.scrollHeight - window.innerHeight;
          if (window.scrollY < maxScroll) {
            window.scrollBy(0, 2);
          }
        })();
      ''');
    });
  }

  void _stopAutoScroll() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    _flutterTts.stop();
    _scrollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '微信文章朗读',
          style: TextStyle(color: Colors.black87),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: TextField(
              controller: _urlController,
              decoration: InputDecoration(
                hintText: '粘贴微信公众号文章链接',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                isDense: true,
                suffixIcon: _isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
              ),
              maxLines: 1,
            ),
          ),
          
          Expanded(
            child: Stack(
              children: [
                WebViewWidget(controller: _webViewController),
                
                if (!_isPageLoaded && !_isLoading)
                  const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.article_outlined, size: 64, color: Colors.grey),
                        SizedBox(height: 8),
                        Text('粘贴链接后点击播放', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                
                if (_isLoading)
                  const Center(
                    child: CircularProgressIndicator(),
                  ),
                
                Center(
                  child: _buildPlayButton(),
                ),
              ],
            ),
          ),
          
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.speed, size: 18),
                const SizedBox(width: 2),
                const Text('慢', style: TextStyle(fontSize: 11)),
                Expanded(
                  child: Slider(
                    value: _speechRate,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: _speechRate.toStringAsFixed(1),
                    onChanged: (value) {
                      setState(() {
                        _speechRate = value;
                      });
                      _flutterTts.setSpeechRate(value);
                    },
                  ),
                ),
                const Text('快', style: TextStyle(fontSize: 11)),
                const SizedBox(width: 2),
                SizedBox(
                  width: 30,
                  child: Text(
                    _speechRate.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayButton() {
    if (!_isPlaying && !_isLoading) {
      return FloatingActionButton.large(
        onPressed: _onPlayPressed,
        child: const Icon(Icons.play_arrow, size: 48),
      );
    }
    
    if (_isLoading) {
      return const SizedBox.shrink();
    }
    
    if (_isPaused) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.large(
            onPressed: _resumeReading,
            backgroundColor: Colors.green,
            child: const Icon(Icons.play_arrow, size: 48, color: Colors.white),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _stopReading,
            child: const Text('停止', style: TextStyle(color: Colors.red)),
          ),
        ],
      );
    }
    
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FloatingActionButton.large(
          onPressed: _pauseReading,
          backgroundColor: Colors.orange,
          child: const Icon(Icons.pause, size: 48, color: Colors.white),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _stopReading,
          child: const Text('停止', style: TextStyle(color: Colors.red)),
        ),
      ],
    );
  }
}
