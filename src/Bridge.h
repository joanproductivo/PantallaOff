/*
 * Bridging header de PantallaOff.
 *
 * Expone a Swift el núcleo C compartido. Swift NO reimplementa el predicado de
 * seguridad: llama al mismo código que usan probe/rescue/selftest, para que no
 * puedan divergir.
 */
#ifndef PANTALLA_BRIDGE_H
#define PANTALLA_BRIDGE_H

#include "PantallaCore.h"

#include <IOKit/pwr_mgt/IOPM.h>

/* kIOPMMessageClamshellStateChange es una macro compuesta (iokit_family_msg)
 * que Swift no puede importar; se re-expone como constante para LidSleep.
 * Los bits (kClamshellStateBit/kClamshellSleepBit) sí importan: son enum C. */
static const uint32_t pcMsgClamshellStateChange = kIOPMMessageClamshellStateChange;

#endif /* PANTALLA_BRIDGE_H */
