#include "MpvVideoItem.h"
#include "PlayerComponent.h"
#include <MpvController>
#include <QDebug>

MpvVideoItem::MpvVideoItem(QQuickItem *parent)
    : MpvAbstractItem(parent)
{
    qDebug() << "MpvVideoItem constructed";
    // Critical: Set vo=libmpv for Qt integration
    Q_EMIT setProperty("vo", "libmpv");

#ifdef Q_OS_WIN32
    // Force desktop OpenGL and disable advanced features for compatibility with older GPUs
    Q_EMIT setProperty("gpu-api", "opengl");
    Q_EMIT setProperty("opengl-es", "no");
#endif

    // Connected here rather than in setPlayerComponent so that the render
    // context is recorded whichever of the two arrives first.
    connect(this, &MpvAbstractItem::ready, this, [this]() {
        qDebug() << "MpvVideoItem render context ready";
        m_renderContextReady = true;
        if (m_readyTimeout)
            m_readyTimeout->stop();
        maybeInitialize();
    });

    m_readyTimeout = new QTimer(this);
    m_readyTimeout->setSingleShot(true);
    m_readyTimeout->setInterval(10000);
    connect(m_readyTimeout, &QTimer::timeout, this, [this]() {
        if (m_initialized || m_renderContextReady)
            return;
        qWarning() << "mpv render context never became ready after 10s — starting "
                      "anyway. Expect audio with no picture; the video item is not "
                      "being rendered by the scene graph.";
        m_renderContextReady = true;
        maybeInitialize();
    });
    m_readyTimeout->start();
}

void MpvVideoItem::setPlayerComponent(PlayerComponent* player)
{
    qDebug() << "MpvVideoItem::setPlayerComponent called, mpvController():" << mpvController();
    m_player = player;
    maybeInitialize();
}

void MpvVideoItem::maybeInitialize()
{
    if (m_initialized || !m_player || !m_renderContextReady)
        return;

    if (!mpvController()) {
        qWarning() << "render context ready but mpvController() is null";
        return;
    }

    qDebug() << "Setting mpv controller and initializing";
    m_initialized = true;
    m_player->setMpvController(mpvController());
    m_player->initializeMpv();
}
