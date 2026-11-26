part of 'study_canvas.dart';

extension _StudyMaterialReader on StudyCanvasState {
  bool _canOpenMaterial(StudyCard card) =>
      card.markdownReader ||
      const {'lecture', 'video', 'pdf', 'pdfdoc'}.contains(card.type);

  void _openMaterialReader(StudyCard card) {
    _fly.stop();
    FocusManager.instance.primaryFocus?.unfocus();
    _update(() {
      _tool = StudyTool.select;
      _focusedMaterial = card;
    });
  }

  void _closeMaterialReader() {
    final card = _focusedMaterial;
    if (card?.type == 'lecture' && _returnToMaterial != null) {
      unawaited(widget.ctl.pause());
    }
    _update(() {
      _focusedMaterial = _returnToMaterial;
      _returnToMaterial = null;
    });
  }

  Widget _materialReader(StudyCard card) {
    if (card.type == 'lecture' && widget.buildLectureReader != null) {
      return widget.buildLectureReader!(_closeMaterialReader);
    }
    if (card.markdownReader) {
      final lessonActive =
          card.lessonNote && _lessonState['noteId'] == card.documentId;
      final page = NotePage.canvas(
        bookmark: lessonActive ? _lessonState['bookmark'] as Map? : null,
        onBookmark: lessonActive
            ? (mark) => _lessonAction('position', {'bookmark': mark})
            : null,
        decorateSection: (text, offset, child) => _markdownPassage(
          card,
          text,
          sectionOffset: offset,
          rendered: child,
        ),
        document: Note({
          'id': card.documentId,
          'title': card.title,
          'body': card.text,
          'path': card.originalPath.isEmpty ? card.source : card.originalPath,
          'course_id': widget._player?.course?.id ?? '',
          'lecture_id': card.sourceLectureId.isEmpty
              ? widget._player?.lectureId ?? ''
              : card.sourceLectureId,
          'source': card.lessonNote || card.pinnedAnswer ? 'agent' : '',
        }),
        onBack: _closeMaterialReader,
        onEdit: document!.editable(card.layer) ? () => _text(card) : null,
        onPlay: _playReadingReference,
      );
      return KeyedSubtree(
        key: _documentReaders.putIfAbsent(card.id, GlobalKey.new),
        child: card.lessonNote ? _lessonReader(card, readingPage: page) : page,
      );
    }
    return Scaffold(
      backgroundColor: card.type == 'video' || card.type == 'lecture'
          ? Colors.black
          : Theme.of(context).colorScheme.surface,
      appBar: AppBar(
        leading: BackButton(onPressed: _closeMaterialReader),
        title: Text(card.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _materialBody(card),
    );
  }

  // Move the live reader between the card body and the expanded view.
  Widget _cardMaterial(StudyCard card) {
    if ((!card.markdownReader &&
            (_focusedMaterial?.id == card.id ||
                _returnToMaterial?.id == card.id)) ||
        (widget.fullscreen && card.type == 'lecture') ||
        (_inlinePDF && card.type == 'pdfdoc' && card.collapsed)) {
      return const SizedBox.shrink();
    }
    final body = _materialBody(card);
    return card.type == 'video' || card.type == 'lecture'
        ? _snapshotVideo(card, _videoInput(body))
        : body;
  }

  Widget _materialBody(StudyCard card) => KeyedSubtree(
    key: _materialReaders.putIfAbsent(card.id, GlobalKey.new),
    child: switch (card.type) {
      'lecture' when widget.ctl.mediaLoading && widget.ctl.source == null =>
        const Center(child: CircularProgressIndicator()),
      'lecture' when widget.ctl.mediaError != null => Center(
        child: Text(l10n.playerNoVideo),
      ),
      'lecture' => widget.video,
      'video' => _LocalVideo(
        key: _localVideoKeys.putIfAbsent(
          card.id,
          () => GlobalKey<_LocalVideoState>(),
        ),
        url: card.path.isEmpty
            ? widget.api.studyMediaUrl(widget.ctl.lectureId, card.id)
            : widget.api.fileUrl(card.path),
        api: widget.api,
        title: card.title,
        prepare: flush,
        focused: _focusedMaterial?.id == card.id,
        onCanvas: showCanvas,
        preview:
            _focusedMaterial?.id == card.id ||
            _previewVideoId == card.id ||
            _bookmarks.lastOrNull?.video == card.id,
        initialMs: _localVideoTimes[card.id] ?? 0,
        onPosition: (ms) => _localVideoTimes[card.id] = ms,
      ),
      'pdfdoc' when _inlinePDF => _CanvasPdf(
        key: _pdfBodies.putIfAbsent(
          card.id,
          () => GlobalKey<_CanvasPdfState>(),
        ),
        owner: this,
        card: card,
      ),
      'pdfdoc' => _PDFBody(owner: this, card: card),
      'pdf' when _pdfPageCard(card) => _CanvasPdf(
        key: _pdfBodies.putIfAbsent(
          card.id,
          () => GlobalKey<_CanvasPdfState>(),
        ),
        owner: this,
        card: card,
        root: document!.cards.firstWhere((p) => p.id == card.pdfColumn),
      ),
      'pdf' => Image.network(
        widget.api.fileUrl(card.path),
        fit: BoxFit.contain,
      ),
      _ when card.lessonNote => _lessonReader(card),
      _ => SingleChildScrollView(
        key: PageStorageKey('study-reader/${card.id}'),
        primary: false,
        physics: _pdfPinching ? const NeverScrollableScrollPhysics() : null,
        padding: const EdgeInsets.all(18),
        child: _markdownPassage(card, card.text),
      ),
    },
  );

  Future<void> _playReadingReference(String lecture, int ms) async {
    if (!mounted || lecture.isEmpty) return;
    final recording = widget.standalone || lecture != widget.ctl.lectureId
        ? null
        : document!.cards.where((card) => card.type == 'lecture').firstOrNull;
    if (recording != null &&
        !widget.ctl.mediaLoading &&
        widget.ctl.mediaError == null &&
        widget.ctl.source != null) {
      _returnToMaterial = _focusedMaterial;
      _openMaterialReader(recording);
      try {
        await widget.ctl.playFrom(ms);
      } catch (_) {
        if (mounted) _toast(l10n.studyVideoUnavailable);
      }
      return;
    }
    if (!widget.standalone) unawaited(widget.ctl.pause());
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => PlayerPage(lectureId: lecture, startMs: ms),
      ),
    );
  }

  Future<void> _importDroppedFiles(List<DropItemFile> files, Offset at) async {
    final access = <Uint8List>[];
    try {
      if (Platform.isMacOS) {
        for (final file in files) {
          if (file.extraAppleBookmark case final bookmark?) {
            if (await DesktopDrop.instance.startAccessingSecurityScopedResource(
              bookmark: bookmark,
            )) {
              access.add(bookmark);
            }
          }
        }
      }
      if (mounted && ModalRoute.isCurrentOf(context) == true) {
        await _import(dropped: files, at: at);
      }
    } catch (e) {
      if (mounted) _toast(l10n.studyImportError('$e'));
    } finally {
      for (final bookmark in access) {
        try {
          await DesktopDrop.instance.stopAccessingSecurityScopedResource(
            bookmark: bookmark,
          );
        } on PlatformException {
          // Release the remaining grants even if a source has disappeared.
        }
      }
    }
  }

  Future<void> _seedLessonMaterials(StudyDocument d) async {
    if (_seedingMaterials) return;
    _seedingMaterials = true;
    try {
      final player = widget.ctl;
      final note = player.notes
          .where((n) => n.lectureId == player.lectureId)
          .firstOrNull;
      final cards = <StudyCard>[];
      final video = d.cards.firstWhere((c) => c.type == 'lecture');
      final right = Offset(video.rect.right + 36, video.rect.top);
      if (note != null) {
        try {
          final card = await _noteCard(note.id);
          if (card != null) {
            card.rect = right & card.rect.size;
            cards.add(card);
          }
        } catch (_) {
          // A note may still be syncing when its catalog entry arrives.
        }
      }
      if (!mounted || document != d || d.edit != 0) return;
      try {
        final files =
            jsonList(
                  await widget.api.get(
                    '/api/lectures/${player.lectureId}/courseware',
                  ),
                )
                .whereType<Map>()
                .map((m) => CoursewareFile(m.cast<String, dynamic>()));
        final pdf = files.where((f) => f.ext == 'pdf').firstOrNull;
        if (pdf != null && mounted && document == d && d.edit == 0) {
          final result = await widget.api.importStudyCourseware(
            player.lectureId,
            pdf.path,
          );
          var position = cards.isEmpty
              ? right
              : video.rect.bottomLeft + const Offset(0, 36);
          for (final data in result['objects'] as List) {
            final card = StudyCard.fromJson(data as Map)..layer = d.activeLayer;
            card.rect = position & card.rect.size;
            cards.add(card);
            position += Offset(card.rect.width + 36, 0);
          }
        }
      } catch (_) {
        // The material shelf keeps files that cannot yet be opened on the canvas.
      }
      if (!mounted || document != d || d.edit != 0 || cards.isEmpty) return;
      d.checkpoint();
      d.cards.addAll(cards);
      _fit(animate: false);
      d.changed();
      _initialMaterialsEdit = d.edit;
    } catch (_) {
      // A missing local file must not block opening the lesson.
    } finally {
      _seedingMaterials = false;
    }
  }
}
