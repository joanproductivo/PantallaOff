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

#endif /* PANTALLA_BRIDGE_H */
