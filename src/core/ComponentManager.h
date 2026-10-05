#ifndef __COMPONENT_MANAGER_H__
#define __COMPONENT_MANAGER_H__

#include <QObject>
#include <QMap>
#include <QWebChannel>
#ifndef MAHFIN_NATIVE_SHELL
#include <QQmlContext>
#include <QQmlPropertyMap>
#endif

#include "utils/Utils.h"

class ComponentBase : public QObject
{
public:
  explicit ComponentBase(QObject* parent = nullptr) : QObject(parent) { }
  
  virtual bool componentInitialize() = 0;
  virtual const char* componentName() = 0;
  virtual bool componentExport() = 0;

  // executed after ALL components are initialized
  virtual void componentPostInitialize() { }
};

class ComponentManager : public QObject
{
  Q_OBJECT
  DEFINE_SINGLETON(ComponentManager);

public:
  void initialize();
#ifndef MAHFIN_NATIVE_SHELL
  inline QQmlPropertyMap &getQmlPropertyMap() { return m_qmlProperyMap; }
#endif
  void setWebChannel(QWebChannel* webChannel);

private:
  ComponentManager();
  void registerComponent(ComponentBase* comp);

  QMap<QString, ComponentBase*> m_components;
#ifndef MAHFIN_NATIVE_SHELL
  QQmlPropertyMap m_qmlProperyMap;
#endif
};

#endif
