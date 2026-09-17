#ifndef MPVVIDEOITEM_H
#define MPVVIDEOITEM_H

#include <MpvAbstractItem>
#include <QTimer>

class PlayerComponent;

class MpvVideoItem : public MpvAbstractItem
{
    Q_OBJECT
    QML_ELEMENT

public:
    explicit MpvVideoItem(QQuickItem *parent = nullptr);
    void setPlayerComponent(PlayerComponent* player);

    MpvController* controller() { return mpvController(); }

private:
    /**
     * Initialises the player once *both* halves are in place, whichever arrives
     * last: the PlayerComponent, and mpv's render context.
     *
     * The second half is the subtle one. MpvAbstractItem creates its mpv handle
     * in its constructor, so mpvController() is non-null almost immediately —
     * but the render context is only created the first time the scene graph
     * renders this item, several hundred milliseconds later, which is what
     * ready() announces.
     *
     * Initialising in between is what this exists to prevent. PlayerComponent
     * sets `force-window`, which makes mpv open the video output there and
     * then; with no render context yet, vo_libmpv fails with "No render context
     * set" and the VO stays dead for the rest of the session. Audio plays
     * normally and no picture ever appears. Because it is a race against the
     * first frame, it happens on some launches and not others.
     */
    void maybeInitialize();

    PlayerComponent* m_player = nullptr;
    bool m_renderContextReady = false;
    bool m_initialized = false;

    /**
     * Last resort, so that a platform where the render context never arrives
     * degrades to audio rather than to nothing at all.
     *
     * Waiting for ready() is correct, but it is a promise this class cannot
     * keep on its own: the signal only fires when the scene graph renders the
     * item, and if that never happens — a broken GL setup, an item culled for
     * a reason we have not met — nothing would ever initialise mpv and the app
     * would sit there doing nothing, with no error anywhere.
     *
     * The timeout is far longer than the wait ever is in practice (measured at
     * about 400ms), so it cannot reintroduce the race it exists behind. When it
     * does fire it says so loudly, because audio-only playback is a symptom
     * somebody will otherwise spend an evening on.
     */
    QTimer* m_readyTimeout = nullptr;
};

#endif // MPVVIDEOITEM_H
